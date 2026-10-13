# HarmonyX probe (BepInEx 5)

Small BepInEx 5 plugin (`com.peakpack.harmonyprobe`, MIT, ours) that checks whether HarmonyX
patching works in the running Unity Mono process. Used for the native macOS arm64 test slot.

## What it checks

Each check logs one line: `HARMONYPROBE check <name>=ok|FAIL (<detail>)`.

| check | patch | expected |
|---|---|---|
| prefix_arg | prefix changes argument of own `NoInlining` method | 101 |
| postfix_result | postfix doubles result of own `NoInlining` method | 8 |
| transpiler_const | transpiler replaces constant 7 with 9 | 9 |
| bcl_postfix_path_combine | postfix on `System.IO.Path.Combine(string,string)` (marker input only) | `PATCHED:x` |
| unity_managed_prefix_lerp | prefix on `UnityEngine.Mathf.Lerp` (managed, not icall) forces `t = 1` | 10 |

Then it unpatches (`Harmony.UnpatchSelf`) and checks the originals are back.
The final line is `HARMONYPROBE RESULT PASS` or `HARMONYPROBE RESULT FAIL <n>`.
The start line records OS, process arch, CLR version, Unity version and platform.

Patches are active only during `Awake`. The `Mathf.Lerp` patch is global while active, so
it is applied and removed in the same call.

## Build

Needs the .NET 10 SDK (`C:\Program Files\dotnet`). Packages come from NuGet.org (HarmonyX 2.9.0)
and https://nuget.bepinex.dev (BepInEx.BaseLib 5.4.21, UnityEngine.Modules 6000.3.15), set in `NuGet.Config`.
All references are compile-only, so only `HarmonyProbe.dll` is produced.

```
dotnet restore HarmonyProbe.csproj
dotnet build HarmonyProbe.csproj -c Release -o ../../../tools/nativework/harmony_probe/out
```

Intermediates go to `tools/nativework/harmony_probe/{obj,bin}`. Nothing is built into this folder.

## Install for a test

Copy `HarmonyProbe.dll` to `<game folder>/BepInEx/plugins/`. Read `BepInEx/LogOutput.log` and grep `HARMONYPROBE`.
