/*
 * d3d11_clear.c - minimal D3D11 clear/present/read-back probe for gate G-A1 (DXMT proof).
 * Part of PeakPack for Mac (mac/testkit). MIT licence.
 *
 * Opens a window, creates a hardware D3D11 device + swap chain, clears to a cycling colour and
 * presents N frames, reads one pixel back through a staging texture, and reports which d3d11.dll
 * was loaded (Wine builtin vs native-style DXMT) and whether DXMT's winemetal.dll is in the process.
 * Prints "RESULT key=value" lines (parsed by gates/G-A1.sh). Never touches the registry or files.
 *
 * Build (CI, llvm-mingw; or Zig):
 *   x86_64-w64-mingw32-clang -O2 -Wall -Wextra -o d3d11_clear.exe d3d11_clear.c -ld3d11 -ldxgi -ldxguid -luser32
 *   zig cc -target x86_64-windows-gnu -O2 -o d3d11_clear.exe d3d11_clear.c -ld3d11 -ldxgi -ldxguid -luser32
 * Usage: d3d11_clear.exe [--frames N] [--width W] [--height H] [--hold-ms N] [--no-vsync]
 * Exit: 0 ok, 2 usage, 3 window, 4 device/swap chain, 5 render target, 6 read-back mismatch/failure.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_CLOSE) { DestroyWindow(h); return 0; }
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

static int pump(void)
{
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
    {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 1;
}

static void print_module(const char *key, const wchar_t *name)
{
    HMODULE m = GetModuleHandleW(name);
    wchar_t path[MAX_PATH];
    char utf8[MAX_PATH * 3];
    if (!m) { printf("RESULT %s_loaded=0\n", key); return; }
    path[0] = 0;
    GetModuleFileNameW(m, path, MAX_PATH);
    WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, sizeof(utf8), NULL, NULL);
    /* Wine marks its own builtin PE modules with this string right after the DOS header. */
    printf("RESULT %s_loaded=1\nRESULT %s_path=%s\nRESULT %s_wine_builtin=%d\n", key, key, utf8, key,
           memcmp((const char *)m + 0x40, "Wine builtin DLL", 16) == 0);
}

static void set_color(int i, float *c)
{
    int phase = i % 180;
    c[0] = (phase < 60) ? 0.8f : 0.1f;
    c[1] = (phase >= 60 && phase < 120) ? 0.8f : 0.1f;
    c[2] = (phase >= 120) ? 0.8f : 0.1f;
    c[3] = 1.0f;
}

int main(int argc, char **argv)
{
    int frames = 300, width = 640, height = 360, hold_ms = 3000, vsync = 1, i, rc = 0;
    HWND hwnd;
    WNDCLASSEXW wc;
    DXGI_SWAP_CHAIN_DESC sd;
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
    D3D_FEATURE_LEVEL got = 0;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    ID3D11Texture2D *bb = NULL, *staging = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    IDXGIDevice *dxgidev = NULL;
    IDXGIAdapter *adapter = NULL;
    HRESULT hr;
    LARGE_INTEGER f, t0, t1;
    int present_fail = 0, done = 0;
    const char *effect = "flip_discard";

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--width") && i + 1 < argc) width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i + 1 < argc) height = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--hold-ms") && i + 1 < argc) hold_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-vsync")) vsync = 0;
        else { fprintf(stderr, "usage: %s [--frames N] [--width W] [--height H] [--hold-ms N] [--no-vsync]\n", argv[0]); return 2; }
    }
    if (frames < 1 || width < 16 || height < 16) { fprintf(stderr, "bad arguments\n"); return 2; }
    printf("RESULT probe=d3d11_clear\nRESULT probe_version=1\n");

    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.lpszClassName = L"PeakPackD3D11Probe";
    RegisterClassExW(&wc);
    hwnd = CreateWindowExW(0, wc.lpszClassName, L"PeakPack D3D11 probe (G-A1)", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                           CW_USEDEFAULT, CW_USEDEFAULT, width, height, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("RESULT window=fail\nRESULT exit=3\n"); return 3; }
    printf("RESULT window=ok\n");

    memset(&sd, 0, sizeof(sd));
    sd.BufferCount = 2;
    sd.BufferDesc.Width = (UINT)width;
    sd.BufferDesc.Height = (UINT)height;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = (DXGI_SWAP_EFFECT)4; /* DXGI_SWAP_EFFECT_FLIP_DISCARD (Unity's choice) */

    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 4, D3D11_SDK_VERSION,
                                       &sd, &sc, &dev, &got, &ctx);
    if (hr == E_INVALIDARG) /* runtimes without 11_1 */
        hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels + 1, 3, D3D11_SDK_VERSION,
                                           &sd, &sc, &dev, &got, &ctx);
    if (FAILED(hr))
    {
        printf("RESULT flip_discard_hr=0x%08lx\n", (unsigned long)hr);
        sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
        sd.BufferCount = 1;
        effect = "discard";
        hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels + 1, 3, D3D11_SDK_VERSION,
                                           &sd, &sc, &dev, &got, &ctx);
    }
    printf("RESULT create_hr=0x%08lx\nRESULT swap_effect=%s\n", (unsigned long)hr, effect);
    if (FAILED(hr)) { printf("RESULT device=fail\nRESULT exit=4\n"); return 4; }
    printf("RESULT device=ok\nRESULT feature_level=0x%x\n", (unsigned)got);

    print_module("d3d11", L"d3d11.dll");
    print_module("dxgi", L"dxgi.dll");
    print_module("winemetal", L"winemetal.dll");

    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgidev)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgidev, &adapter)))
    {
        DXGI_ADAPTER_DESC ad;
        char name[256];
        if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &ad)))
        {
            WideCharToMultiByte(CP_UTF8, 0, ad.Description, -1, name, sizeof(name), NULL, NULL);
            printf("RESULT adapter=%s\nRESULT vendor_id=0x%04x\nRESULT device_id=0x%04x\nRESULT dedicated_video_mb=%lu\n",
                   name, ad.VendorId, ad.DeviceId, (unsigned long)(ad.DedicatedVideoMemory >> 20));
        }
        IDXGIAdapter_Release(adapter);
        IDXGIDevice_Release(dxgidev);
    }

    hr = IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    if (FAILED(hr)) { printf("RESULT rtv=fail\nRESULT rtv_hr=0x%08lx\nRESULT exit=5\n", (unsigned long)hr); return 5; }

    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < frames && !done; i++)
    {
        float c[4];
        if (!pump()) { done = 1; break; }
        set_color(i, c);
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        if (FAILED(IDXGISwapChain_Present(sc, vsync ? 1 : 0, 0))) present_fail++;
    }
    QueryPerformanceCounter(&t1);
    {
        double secs = (double)(t1.QuadPart - t0.QuadPart) / (double)f.QuadPart;
        printf("RESULT frames=%d\nRESULT present_failures=%d\nRESULT seconds=%.3f\nRESULT fps=%.1f\n",
               i, present_fail, secs, secs > 0 ? i / secs : 0.0);
    }

    /* Read-back: clear to a known colour, copy the back buffer to a staging texture BEFORE presenting. */
    {
        const float known[4] = { 0.25f, 0.5f, 0.75f, 1.0f };
        D3D11_TEXTURE2D_DESC td;
        D3D11_MAPPED_SUBRESOURCE map;
        ID3D11Texture2D_GetDesc(bb, &td);
        td.Usage = D3D11_USAGE_STAGING;
        td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        td.MiscFlags = 0;
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, known);
        hr = ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging);
        if (SUCCEEDED(hr))
        {
            ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)bb);
            hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
        }
        if (SUCCEEDED(hr))
        {
            const unsigned char *p = (const unsigned char *)map.pData + (size_t)(height / 2) * map.RowPitch + (size_t)(width / 2) * 4;
            int ok = abs(p[0] - 64) <= 2 && abs(p[1] - 128) <= 2 && abs(p[2] - 191) <= 2 && p[3] == 255;
            printf("RESULT readback=%u,%u,%u,%u\nRESULT readback_expected=64,128,191,255\nRESULT readback_ok=%d\n", p[0], p[1], p[2], p[3], ok);
            ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
            if (!ok) rc = 6;
        }
        else
        {
            printf("RESULT readback_ok=0\nRESULT readback_hr=0x%08lx\n", (unsigned long)hr);
            rc = 6;
        }
        IDXGISwapChain_Present(sc, 1, 0);
    }

    /* Keep the last frame on screen so a screenshot can be taken. */
    {
        DWORD end = GetTickCount() + (DWORD)hold_ms;
        while (GetTickCount() < end && pump()) Sleep(15);
    }

    if (staging) ID3D11Texture2D_Release(staging);
    if (rtv) ID3D11RenderTargetView_Release(rtv);
    if (bb) ID3D11Texture2D_Release(bb);
    if (sc) IDXGISwapChain_Release(sc);
    if (ctx) ID3D11DeviceContext_Release(ctx);
    if (dev) ID3D11Device_Release(dev);
    DestroyWindow(hwnd);
    printf("RESULT exit=%d\n", rc);
    return rc;
}
