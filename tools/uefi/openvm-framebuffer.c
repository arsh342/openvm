/* openvm-framebuffer.c — a linear framebuffer for Windows on Apple's firmware.
 *
 * Apple's firmware draws to the virtual GPU only by Blt (copying pixel blocks);
 * it advertises no framebuffer memory. Windows Boot Manager and the WinPE
 * kernel's boot display need one. This boot-service driver gives every
 * Graphics Output Protocol instance the firmware exposes one shared linear
 * framebuffer in reserved RAM, and copies the rows that change onto the real
 * scanout through the firmware's own Blt every 40 ms. At ExitBootServices it
 * stops; the OS owns the display from then on.
 *
 * It must be built as an EFI *boot service driver*, not an application: the
 * firmware unloads an application's image when its entry point returns, and
 * every hook below would then point into freed memory (the VM faulted ~1 s in,
 * at the first draw, when this was built as an application).
 *
 * Design, in order:
 *   1. hook QueryMode/SetMode/Blt on every GOP instance;
 *   2. pick the instance with a device path as the scanout owner and move it
 *      to the largest mode the framebuffer can hold (the firmware's default
 *      8192x4320 cannot be backed);
 *   3. allocate the framebuffer as EfiReservedMemoryType, so the OS memory
 *      manager never reclaims what the boot manager handed it as a display;
 *   4. advertise every instance as linear BGRX over that memory;
 *   5. flush changed rows on a timer; stop at ExitBootServices;
 *   6. after ConnectController, adopt any GOP instance that appeared.
 *
 * Freestanding: no C library, no EDK2 library.
 * Written against the UEFI specification.
 */

#include <Uefi.h>
#include <Protocol/GraphicsOutput.h>

static EFI_GUID gGopGuid = {
    0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}};
static EFI_GUID gDevicePathGuid = {
    0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID gExitBootServicesGuid = {
    0x27abf055, 0xb1b8, 0x4c26, {0x80, 0x48, 0x74, 0x8f, 0x37, 0xba, 0xa2, 0xdf}};
/* Installed once the driver is running; a second load (firmware Driver0000 and
 * then the chainloader on a fallback boot) finds it and stops. */
static EFI_GUID gOpenVMFbGuid = {
    0x6f70656e, 0x766d, 0x2d02, {0x46, 0x42, 0x9a, 0x3c, 0x1d, 0x77, 0x55, 0x0e}};
static EFI_GUID gOpenVMVendorGuid = {
    0x6f70656e, 0x766d, 0x2d01, {0x49, 0x02, 0x9a, 0x3c, 0x1d, 0x77, 0x55, 0x0e}};

#define CAP_W 1920
#define CAP_H 1200
#define CAP_SIZE ((UINTN)CAP_W * CAP_H * 4)
#define MAX_GOPS 32
#define FLUSH_100NS 400000 /* 40 ms */

static struct {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *gop;
    EFI_GRAPHICS_OUTPUT_PROTOCOL_QUERY_MODE query_mode;
    EFI_GRAPHICS_OUTPUT_PROTOCOL_SET_MODE set_mode;
    EFI_GRAPHICS_OUTPUT_PROTOCOL_BLT blt;
    BOOLEAN has_dp;
} gHooks[MAX_GOPS];
static UINTN gHookCount;

static EFI_BOOT_SERVICES *gBS;
static EFI_RUNTIME_SERVICES *gRT;
static EFI_PHYSICAL_ADDRESS gFrameBase;
static UINTN gFrameSize;
static EFI_GRAPHICS_OUTPUT_PROTOCOL *gDeviceGop;
static EFI_GRAPHICS_OUTPUT_PROTOCOL_BLT gDeviceBlt;
static UINT8 *gShadow;
static BOOLEAN gFlushing;

/* The compiler may emit calls to these even in freestanding code. */
void *memcpy(void *dst, const void *src, UINTN n) {
    UINT8 *d = dst;
    const UINT8 *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}
void *memset(void *dst, int c, UINTN n) {
    UINT8 *d = dst;
    while (n--)
        *d++ = (UINT8)c;
    return dst;
}

static UINTN mode_size(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
    return (UINTN)info->HorizontalResolution * (UINTN)info->VerticalResolution * 4;
}

static int hook_index(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop) {
    for (UINTN i = 0; i < gHookCount; i++)
        if (gHooks[i].gop == gop)
            return (int)i;
    return -1;
}

/* Linear BGRX, one pixel per scanline column. */
static void advertise_mode(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
    info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
    info->PixelInformation.RedMask = 0;
    info->PixelInformation.GreenMask = 0;
    info->PixelInformation.BlueMask = 0;
    info->PixelInformation.ReservedMask = 0;
    info->PixelsPerScanLine = info->HorizontalResolution;
}

/* Point one instance's current mode at our framebuffer, if it fits. */
static void patch_gop(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode = gop->Mode;
    if (gFrameSize == 0 || mode == NULL || mode->Info == NULL || mode_size(mode->Info) > gFrameSize)
        return;
    advertise_mode(mode->Info);
    mode->FrameBufferBase = gFrameBase;
    mode->FrameBufferSize = mode_size(mode->Info);
}

static EFI_STATUS EFIAPI hooked_query_mode(EFI_GRAPHICS_OUTPUT_PROTOCOL *This, UINT32 ModeNumber,
                                           UINTN *SizeOfInfo,
                                           EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **Info) {
    int i = hook_index(This);
    if (i < 0)
        return EFI_INVALID_PARAMETER;
    EFI_STATUS st = gHooks[i].query_mode(This, ModeNumber, SizeOfInfo, Info);
    if (st == EFI_SUCCESS && Info != NULL && *Info != NULL && gFrameSize != 0 &&
        mode_size(*Info) <= gFrameSize)
        advertise_mode(*Info);
    return st;
}

static EFI_STATUS EFIAPI hooked_set_mode(EFI_GRAPHICS_OUTPUT_PROTOCOL *This, UINT32 ModeNumber) {
    int i = hook_index(This);
    if (i < 0)
        return EFI_INVALID_PARAMETER;
    if (gFrameSize != 0) {
        UINTN size = 0;
        EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = NULL;
        if (gHooks[i].query_mode(This, ModeNumber, &size, &info) != EFI_SUCCESS || info == NULL)
            return EFI_UNSUPPORTED;
        UINTN need = mode_size(info);
        gBS->FreePool(info);
        if (need > gFrameSize)
            return EFI_UNSUPPORTED; /* only modes we can back */
    }
    EFI_STATUS st = gHooks[i].set_mode(This, ModeNumber);
    if (st == EFI_SUCCESS)
        patch_gop(This);
    return st;
}

/* Blt over the shared framebuffer; the flush timer carries it to the scanout. */
static EFI_STATUS EFIAPI hooked_blt(EFI_GRAPHICS_OUTPUT_PROTOCOL *This,
                                    EFI_GRAPHICS_OUTPUT_BLT_PIXEL *BltBuffer,
                                    EFI_GRAPHICS_OUTPUT_BLT_OPERATION Op, UINTN SourceX,
                                    UINTN SourceY, UINTN DestinationX, UINTN DestinationY,
                                    UINTN Width, UINTN Height, UINTN Delta) {
    int i = hook_index(This);
    if (i < 0)
        return EFI_INVALID_PARAMETER;
    if (gFrameBase == 0 || This->Mode == NULL || This->Mode->Info == NULL ||
        This->Mode->FrameBufferBase != gFrameBase)
        return gHooks[i].blt(This, BltBuffer, Op, SourceX, SourceY, DestinationX, DestinationY,
                             Width, Height, Delta);
    if (Op >= EfiGraphicsOutputBltOperationMax || (Op != EfiBltVideoToVideo && BltBuffer == NULL))
        return EFI_INVALID_PARAMETER;
    if (Width == 0 || Height == 0)
        return EFI_SUCCESS;
    UINTN fw = This->Mode->Info->HorizontalResolution;
    UINTN fh = This->Mode->Info->VerticalResolution;
    if (DestinationX + Width > fw || DestinationY + Height > fh)
        return EFI_INVALID_PARAMETER;
    if ((Op == EfiBltVideoToBltBuffer || Op == EfiBltVideoToVideo) &&
        (SourceX + Width > fw || SourceY + Height > fh))
        return EFI_INVALID_PARAMETER;

    UINT8 *fb = (UINT8 *)(UINTN)gFrameBase;
    UINTN vrow = fw * 4;
    UINTN brow = Delta != 0 ? Delta : Width * 4;
    switch (Op) {
    case EfiBltVideoFill: {
        UINT8 b = BltBuffer[0].Blue, g = BltBuffer[0].Green, r = BltBuffer[0].Red;
        for (UINTN y = 0; y < Height; y++) {
            UINT8 *d = fb + (DestinationY + y) * vrow + DestinationX * 4;
            for (UINTN x = 0; x < Width; x++) {
                d[x * 4 + 0] = b;
                d[x * 4 + 1] = g;
                d[x * 4 + 2] = r;
                d[x * 4 + 3] = 0;
            }
        }
        break;
    }
    case EfiBltVideoToBltBuffer:
        for (UINTN y = 0; y < Height; y++)
            memcpy((UINT8 *)BltBuffer + (DestinationY + y) * brow + DestinationX * 4,
                   fb + (SourceY + y) * vrow + SourceX * 4, Width * 4);
        break;
    case EfiBltBufferToVideo:
        for (UINTN y = 0; y < Height; y++)
            memcpy(fb + (DestinationY + y) * vrow + DestinationX * 4,
                   (UINT8 *)BltBuffer + (SourceY + y) * brow + SourceX * 4, Width * 4);
        break;
    case EfiBltVideoToVideo:
        for (UINTN k = 0; k < Height; k++) {
            UINTN y = DestinationY > SourceY ? Height - 1 - k : k; /* overlap-safe */
            UINT8 *s = fb + (SourceY + y) * vrow + SourceX * 4;
            UINT8 *d = fb + (DestinationY + y) * vrow + DestinationX * 4;
            if (d <= s)
                for (UINTN x = 0; x < Width * 4; x++)
                    d[x] = s[x];
            else
                for (UINTN x = Width * 4; x-- > 0;)
                    d[x] = s[x];
        }
        break;
    default:
        return EFI_INVALID_PARAMETER;
    }
    return EFI_SUCCESS;
}

static void push_rows(UINTN y, UINTN height, UINTN width) {
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = gDeviceGop->Mode->Info;
    UINTN w = info->HorizontalResolution, h = info->VerticalResolution;
    if (!gFlushing || y >= h || width == 0 || height == 0)
        return;
    if (width > w)
        width = w;
    if (height > h - y)
        height = h - y;
    gDeviceBlt(gDeviceGop, (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)(UINTN)gFrameBase, EfiBltBufferToVideo,
               0, y, 0, y, width, height, w * 4);
}

static BOOLEAN rows_equal(const UINT8 *a, const UINT8 *b, UINTN n) {
    while (n--)
        if (*a++ != *b++)
            return FALSE;
    return TRUE;
}

/* Windows writes pixels directly; push whichever rows changed. */
static void EFIAPI flush_frame(EFI_EVENT event, void *context) {
    (void)event;
    (void)context;
    if (!gFlushing || gShadow == NULL || gDeviceGop == NULL || gDeviceGop->Mode == NULL)
        return;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = gDeviceGop->Mode->Info;
    if (info == NULL || gDeviceGop->Mode->FrameBufferBase != gFrameBase ||
        mode_size(info) > gFrameSize)
        return;
    UINTN width = info->HorizontalResolution, height = info->VerticalResolution, stride = width * 4;
    UINT8 *fb = (UINT8 *)(UINTN)gFrameBase;
    UINTN run = 0;
    BOOLEAN in = FALSE;
    for (UINTN row = 0; row < height; row++) {
        UINT8 *cur = fb + row * stride, *prev = gShadow + row * stride;
        if (!rows_equal(cur, prev, stride)) {
            memcpy(prev, cur, stride);
            if (!in) {
                run = row;
                in = TRUE;
            }
        } else if (in) {
            push_rows(run, row - run, width);
            in = FALSE;
        }
    }
    if (in)
        push_rows(run, height - run, width);
}

static void EFIAPI stop_flushing(EFI_EVENT event, void *context) {
    (void)event;
    (void)context;
    gFlushing = FALSE;
}

/* Hook every GOP instance not hooked yet; returns how many were added. */
static UINTN hook_pass(void) {
    EFI_HANDLE *handles = NULL;
    UINTN count = 0, added = 0;
    if (gBS->LocateHandleBuffer(ByProtocol, &gGopGuid, NULL, &count, &handles) != EFI_SUCCESS ||
        handles == NULL)
        return 0;
    for (UINTN i = 0; i < count && gHookCount < MAX_GOPS; i++) {
        EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = NULL;
        void *dp = NULL;
        if (gBS->HandleProtocol(handles[i], &gGopGuid, (void **)&gop) != EFI_SUCCESS ||
            gop == NULL || hook_index(gop) >= 0)
            continue;
        gHooks[gHookCount].gop = gop;
        gHooks[gHookCount].query_mode = gop->QueryMode;
        gHooks[gHookCount].set_mode = gop->SetMode;
        gHooks[gHookCount].blt = gop->Blt;
        gHooks[gHookCount].has_dp =
            gBS->HandleProtocol(handles[i], &gDevicePathGuid, &dp) == EFI_SUCCESS && dp != NULL;
        gop->QueryMode = hooked_query_mode;
        gop->SetMode = hooked_set_mode;
        gop->Blt = hooked_blt;
        gHookCount++;
        added++;
    }
    gBS->FreePool(handles);
    return added;
}

static void publish(const char *text) {
    CHAR8 buf[96];
    UINTN n = 0;
    while (*text && n < sizeof buf - 1)
        buf[n++] = (CHAR8)*text++;
    gRT->SetVariable(L"OpenVMFB", &gOpenVMVendorGuid,
                     EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS |
                         EFI_VARIABLE_RUNTIME_ACCESS,
                     n, buf);
}

EFI_STATUS EFIAPI EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    (void)ImageHandle;
    gBS = SystemTable->BootServices;
    gRT = SystemTable->RuntimeServices;

    void *already = NULL;
    if (gBS->LocateProtocol(&gOpenVMFbGuid, NULL, &already) == EFI_SUCCESS)
        return EFI_ALREADY_STARTED;

    hook_pass();
    for (UINTN i = 0; i < gHookCount && gDeviceGop == NULL; i++)
        if (gHooks[i].has_dp && gHooks[i].gop->Mode != NULL && gHooks[i].gop->Mode->Info != NULL)
            gDeviceGop = gHooks[i].gop;
    if (gDeviceGop == NULL && gHookCount > 0 && gHooks[0].gop->Mode != NULL &&
        gHooks[0].gop->Mode->Info != NULL)
        gDeviceGop = gHooks[0].gop;
    if (gDeviceGop == NULL) {
        publish("openvm-fb no-gop");
        return EFI_UNSUPPORTED;
    }
    int di = hook_index(gDeviceGop);

    /* The firmware's default mode is larger than any framebuffer we can back:
     * move to the largest mode within the cap. */
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode = gDeviceGop->Mode;
    if (mode_size(mode->Info) > CAP_SIZE) {
        UINT32 best = mode->MaxMode;
        UINTN best_size = 0;
        for (UINT32 m = 0; m < mode->MaxMode; m++) {
            UINTN sz = 0;
            EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *mi = NULL;
            if (gHooks[di].query_mode(gDeviceGop, m, &sz, &mi) != EFI_SUCCESS || mi == NULL)
                continue;
            if (mode_size(mi) <= CAP_SIZE && mode_size(mi) > best_size) {
                best = m;
                best_size = mode_size(mi);
            }
            gBS->FreePool(mi);
        }
        if (best >= mode->MaxMode || gHooks[di].set_mode(gDeviceGop, best) != EFI_SUCCESS) {
            publish("openvm-fb no-mode");
            return EFI_UNSUPPORTED;
        }
    }

    UINTN bytes = mode_size(gDeviceGop->Mode->Info);
    UINTN pages = (bytes + 0xfff) / 0x1000;
    EFI_PHYSICAL_ADDRESS base = 0;
    if (gBS->AllocatePages(AllocateAnyPages, EfiReservedMemoryType, pages, &base) != EFI_SUCCESS &&
        gBS->AllocatePages(AllocateAnyPages, EfiLoaderData, pages, &base) != EFI_SUCCESS) {
        publish("openvm-fb no-memory");
        return EFI_OUT_OF_RESOURCES;
    }
    gBS->SetMem((void *)(UINTN)base, pages * 0x1000, 0);
    gFrameBase = base;
    gFrameSize = bytes;
    if (gBS->AllocatePool(EfiBootServicesData, bytes, (void **)&gShadow) == EFI_SUCCESS)
        gBS->SetMem(gShadow, bytes, 0);
    gDeviceBlt = gHooks[di].blt; /* the scanout's own Blt, for the flush */

    for (UINTN i = 0; i < gHookCount; i++)
        patch_gop(gHooks[i].gop);

    EFI_EVENT timer = NULL, ebs = NULL;
    if (gShadow != NULL &&
        gBS->CreateEvent(EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, flush_frame, NULL, &timer) ==
            EFI_SUCCESS &&
        gBS->SetTimer(timer, TimerPeriodic, FLUSH_100NS) == EFI_SUCCESS)
        gFlushing = TRUE;
    gBS->CreateEventEx(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, stop_flushing, NULL, &gExitBootServicesGuid,
                       &ebs);

    /* Instances born from a controller pass would otherwise be unhooked. */
    EFI_HANDLE *all = NULL;
    UINTN all_count = 0;
    if (gBS->LocateHandleBuffer(AllHandles, NULL, NULL, &all_count, &all) == EFI_SUCCESS && all) {
        for (UINTN i = 0; i < all_count; i++)
            gBS->ConnectController(all[i], NULL, NULL, TRUE);
        gBS->FreePool(all);
    }
    hook_pass();
    for (UINTN i = 0; i < gHookCount; i++)
        patch_gop(gHooks[i].gop);

    EFI_HANDLE marker = NULL;
    gBS->InstallProtocolInterface(&marker, &gOpenVMFbGuid, EFI_NATIVE_INTERFACE, NULL);

    /* Where the pixels are and their geometry, for the host's memory tap:
     * "openvm-fb ok base=0x<hex> w=<dec> h=<dec>". */
    char msg[80] = "openvm-fb ok base=0x";
    UINTN n = 20;
    for (int shift = 60; shift >= 0; shift -= 4) {
        UINT8 d = (UINT8)((base >> shift) & 0xF);
        msg[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    }
    UINT64 dims[2] = {gDeviceGop->Mode->Info->HorizontalResolution,
                      gDeviceGop->Mode->Info->VerticalResolution};
    const char *labels[2] = {" w=", " h="};
    for (int k = 0; k < 2; k++) {
        for (const char *l = labels[k]; *l; l++)
            msg[n++] = *l;
        char digits[12];
        int c = 0;
        UINT64 v = dims[k];
        do {
            digits[c++] = (char)('0' + v % 10);
            v /= 10;
        } while (v && c < 12);
        while (c)
            msg[n++] = digits[--c];
    }
    msg[n] = 0;
    publish(msg);
    return EFI_SUCCESS;
}
