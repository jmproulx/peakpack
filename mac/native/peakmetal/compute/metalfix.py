"""Metal-only behaviour Unity's own Mac build compiles into some compute shaders, recreated offline on kernels
translated from the Vulkan build (which lacks the SHADER_API_METAL branches).

1. STP_BUG_SAT_INF (com.unity.render-pipelines.core Runtime/STP/StpCommon.hlsl: defined under SHADER_API_METAL
   "because the shading language spec states that the fast-math option is on by default which disables support
   for proper INF handling"). Without it STP computes StpGtZero(x) = saturate(x * +INF) and
   StpSigned(x) = saturate(x * -INF) (Stp.hlsl); with it, (x > 0) ? 1 : 0 and (x < 0) ? 1 : 0. Under Metal
   fast-math, x * INF is undefined (and 0 * INF = NaN, which D3D's saturate maps to 0 but fast::clamp does not),
   so the Vulkan-derived MSL is rewritten to the STP_BUG_SAT_INF form. Generic: matches only a multiply by a
   literal +-INF whose only use is a [0, 1] clamp, so it is applied to every kernel (in PEAK only StpSetup has it).

2. STP_FORCE_32BIT_REDUCTION (StpSetup.compute: SHADER_API_METAL && !SHADER_API_MOBILE): on desktop Metal the
   16-bit STP path keeps a 32-bit reduction. The Vulkan build has no such kernel, so on Metal every keyword set
   with UNITY_DEVICE_SUPPORTS_NATIVE_16BIT is pointed at the 32-bit kernel of the same keyword set (the existing
   STP_32BIT variant: full precision everywhere, which includes the 32-bit reduction). This also keeps the
   16-bit half-precision +-INF tricks (STP_INFP_H etc.) off the Mac. Applied to StpSetup, StpPreTaa and StpTaa.

Not fixable offline: VFX Graph `Sort` uses USE_ALTERNATE_BITONIC_NETWORK on Metal (Sort.compute: "BitonicSort128
doesn't behave as expected, actual cause isn't identified yet"). The alternate network is a different algorithm
(index1 += step - 2*lsb - 1 when subStep == step; reverse = false) compiled out of every non-Metal build, and no
PEAK variant or keyword contains it; recreating it would mean rewriting the sort loop of 10 kernels by hand with
no golden output to test against. See README-compute.md.
"""
import re

KW_NATIVE_16BIT = "UNITY_DEVICE_SUPPORTS_NATIVE_16BIT"
FORCE_32BIT_SHADERS = ("StpSetup", "StpPreTaa", "StpTaa")

_INF = {"2139095040": "+", "-8388608": "-", "0x7f800000u": "+", "0xff800000u": "-"}
_MUL_STMT = re.compile(r"^(?P<ind>[ \t]*)(?P<v>\w+(?:\.[xyzw])?) \*= as_type<float>\((?P<c>-8388608|2139095040)\);\n",
                       re.M)
_CLAMP_STMT = "{v} = fast::clamp({v}, 0.0, 1.0);"
_INLINE_CONST = re.compile(r" \* as_type<float>\((0x7f800000u|0xff800000u)(?: /\* [+-]?inf \*/)?\)$")


def _select(expr, sign):
    return f"(({expr}) {'>' if sign == '+' else '<'} 0.0 ? 1.0 : 0.0)"


def fix_sat_inf(msl):
    """Return (msl, number of rewrites)."""
    n = 0
    # (a) HLSLcc-style statements:  V *= as_type<float>(-8388608);  ...  V = fast::clamp(V, 0.0, 1.0);
    pos = 0
    while True:
        m = _MUL_STMT.search(msl, pos)
        if not m:
            break
        v, sign = m.group("v"), _INF[m.group("c")]
        base = v.split(".")[0]
        tail = msl[m.end():]
        nxt = re.search(r"(?<![\w.])" + re.escape(base) + r"\b", tail)   # next statement touching V
        if nxt:
            ls = tail.rfind("\n", 0, nxt.start()) + 1
            le = tail.find("\n", nxt.start())
            if le > 0 and tail[ls:le].strip() == _CLAMP_STMT.format(v=v):
                msl = (msl[:m.start()] + f"{m.group('ind')}{v} = {_select(v, sign)};    // STP_BUG_SAT_INF\n"
                       + tail[:ls] + tail[le + 1:])
                n += 1
                pos = m.start() + 1
                continue
        pos = m.end()
    # (b) inline:  fast::clamp(EXPR * as_type<float>(0xff800000u /* -inf */), 0.0, 1.0)
    out, pos = [], 0
    while True:
        i = msl.find("fast::clamp(", pos)
        if i < 0:
            break
        args, j = _split_call(msl, i + len("fast::clamp("))
        if args is not None and len(args) == 3 and args[1] == "0.0" and args[2] == "1.0":
            mm = _INLINE_CONST.search(args[0])
            if mm:
                out.append(msl[pos:i] + _select(args[0][:mm.start()], _INF[mm.group(1)]))
                pos = j
                n += 1
                continue
        out.append(msl[pos:i + 1])
        pos = i + 1
    out.append(msl[pos:])
    return "".join(out), n


def _split_call(text, k):
    """Arguments of a call whose '(' ends just before k. Returns (args, index after ')') or (None, k)."""
    depth, cur, args = 1, [], []
    while k < len(text):
        ch = text[k]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                args.append("".join(cur).strip())
                return args, k + 1
        if ch == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
        k += 1
    return None, k


def force_32bit(shader_name, kernels):
    """Point keyword sets containing UNITY_DEVICE_SUPPORTS_NATIVE_16BIT at the same set without it (Metal kernel
    parents, in place). Returns a list of (kernel, keywords, old index, new index)."""
    if shader_name not in FORCE_32BIT_SHADERS:
        return []
    changes = []
    for k in kernels:
        by_kw = {s: i for s, i in k["variantIndices"]}
        new = []
        for s, i in k["variantIndices"]:
            words = s.split(" ") if s else []
            if KW_NATIVE_16BIT in words:
                base = " ".join(w for w in words if w != KW_NATIVE_16BIT)
                if base in by_kw and by_kw[base] != i:
                    changes.append((k["name"], s, i, by_kw[base]))
                    i = by_kw[base]
            new.append((s, i))
        k["variantIndices"] = new
    return changes
