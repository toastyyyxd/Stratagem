const std = @import("std");
const builtin = @import("builtin");

pub const ISASupport = struct {
    sse2: bool = false,
    sse3: bool = false,
    ssse3: bool = false,
    sse4_1: bool = false,
    sse4_2: bool = false,

    avx: bool = false,
    avx2: bool = false,

    fma: bool = false,

    avx512f: bool = false,
    avx512bw: bool = false,
    avx512dq: bool = false,
    avx512vl: bool = false,
    avx512cd: bool = false,
    avx512vnni: bool = false,
    avx512vbmi: bool = false,
    avx512vbmi2: bool = false,
    avx512bitalg: bool = false,
    avx512vpopcntdq: bool = false,

    vaes: bool = false,
    sha_ni: bool = false,
    gfni: bool = false,

    neon: bool = false,
    neon_fp16: bool = false,
    neon_fp16fma: bool = false,
    neon_dotprod: bool = false,
    neon_i8mm: bool = false,

    sve: bool = false,
    sve2: bool = false,
    sve_bf16: bool = false,
    sve_f32mm: bool = false,
    sve_f64mm: bool = false,
    sve_i8mm: bool = false,

    pub fn detect() @This() {
        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();
        const al = gpa.allocator();
        var self: @This() = .{};
        if (builtin.cpu.arch.isX86()) {
            detectX86Features(&self, al);
        } else if (builtin.target.cpu.arch.isArm()) {
            detectArmFeatures(&self, al);
        } else {
            std.log.warn("Unoptimized for architecture (arch: {}), falling back to defaults. Performance may degrade.", .{builtin.cpu.arch});
        }
        return self;
    }

    fn detectX86Features(self: *@This(), al: std.mem.Allocator) void {
        const features = [_][]const u8{ "sse2", "sse3", "ssse3", "sse4_1", "sse4_2", "avx", "avx2", "avx512f", "avx512bw", "avx512dq", "avx512vl" };
        switch (builtin.os.tag) {
            .linux => {
                if (!detectFeaturesViaCpuinfo(self, al, &features)) {
                    std.log.err("Unable to use /proc/cpuinfo to detect features, falling back to defaults. This may cause performance to degrade.", .{});
                }
            },
            .windows, .macos => {
                if (!detectFeaturesViaX86CpuId(self)) {
                    std.log.err("Unable to use CPUID to detect features, falling back to defaults. This may cause performance to degrade.", .{});
                }
            },
            else => {
                std.log.warn("Unoptimized for platform (OS: {}), falling back to defaults. Performance may degrade.", .{builtin.os.tag});
            },
        }
    }

    fn detectArmFeatures(self: *@This(), al: std.mem.Allocator) void {
        const features = [_][]const u8{ "neon", "neon_fp16", "neon_fp16fma", "neon_dotprod", "neon_i8mm", "sve", "sve2" };
        switch (builtin.os.tag) {
            .linux => {
                if (!detectFeaturesViaCpuinfo(self, al, &features)) {
                    std.log.err("Unable to use /proc/cpuinfo to detect features, falling back to defaults. This may cause performance to degrade.", .{});
                }
            },
            .windows => {
                if (!detectFeaturesViaWindowsArm(self)) {
                    std.log.err("Unable to use Windows ARM feature detection, falling back to defaults. This may cause performance to degrade.", .{});
                }
            },
            .macos, .ios => {
                if (!detectFeaturesViaAppleSilicon(self)) {
                    std.log.err("Unable to use Apple Silicon feature detection, falling back to defaults. This may cause performance to degrade.", .{});
                }
            },
            else => {
                std.log.warn("Unoptimized for platform (OS: {}), falling back to defaults. Performance may degrade.", .{builtin.os.tag});
            },
        }
    }

    fn detectFeaturesViaCpuinfo(self: *@This(), al: std.mem.Allocator, comptime to_check: []const []const u8) bool {
        const file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return false;
        defer file.close();
        var read_buf: [1024]u8 = undefined;
        var file_reader = file.readerStreaming(&read_buf);
        const reader = &file_reader.interface;
        var line = std.Io.Writer.Allocating.init(al);
        defer line.deinit();
        while (true) {
            line.clearRetainingCapacity();
            const n = reader.streamDelimiter(&line.writer, '\n') catch return false;
            if (n == 0) break; // finished block
            reader.toss(1);
            var tokenizer = std.mem.tokenizeAny(u8, line.written(), " :");
            _ = tokenizer.next() orelse continue;
            while (true) {
                const flag_name_b = tokenizer.next() orelse break;
                const flag_name_c = blk: {
                    if (std.mem.eql(u8, flag_name_b, "pni")) break :blk "sse3";
                    if (std.mem.eql(u8, flag_name_b, "asimd")) break :blk "neon";
                    if (std.mem.eql(u8, flag_name_b, "asimdhp")) break :blk "neon_fp16";
                    if (std.mem.eql(u8, flag_name_b, "asimdfhm")) break :blk "neon_fp16fma";
                    if (std.mem.eql(u8, flag_name_b, "asimddp")) break :blk "neon_dotprod";
                    if (std.mem.eql(u8, flag_name_b, "asimdi8mm")) break :blk "neon_i8mm";
                    break :blk flag_name_b;
                };
                inline for (to_check) |flag_name| {
                    const equal = std.mem.eql(u8, flag_name, flag_name_b) or std.mem.eql(u8, flag_name, flag_name_c);
                    if (equal and (!@field(self, flag_name))) {
                        @field(self, flag_name) = true;
                    }
                }
            }
        }
        return true;
    }

    pub fn detectFeaturesViaWindowsX86(self: *ISASupport) bool {
        self.sse = std.os.windows.IsProcessorFeaturePresent(.XMMI_INSTRUCTIONS_AVAILABLE);
        self.sse2 = std.os.windows.IsProcessorFeaturePresent(.XMMI64_INSTRUCTIONS_AVAILABLE);
        self.sse3 = std.os.windows.IsProcessorFeaturePresent(.SSE3_INSTRUCTIONS_AVAILABLE);
        self.ssse3 = std.os.windows.IsProcessorFeaturePresent(.SSSE3_INSTRUCTIONS_AVAILABLE);
        self.sse4_1 = std.os.windows.IsProcessorFeaturePresent(.SSE4_1_INSTRUCTIONS_AVAILABLE);
        self.sse4_2 = std.os.windows.IsProcessorFeaturePresent(.SSE4_2_INSTRUCTIONS_AVAILABLE);
        self.avx = std.os.windows.IsProcessorFeaturePresent(.AVX_INSTRUCTIONS_AVAILABLE);
        self.avx2 = std.os.windows.IsProcessorFeaturePresent(.AVX2_INSTRUCTIONS_AVAILABLE);
        self.avx512f = std.os.windows.IsProcessorFeaturePresent(.AVX512F_INSTRUCTIONS_AVAILABLE);
        return true;
    }

    pub fn detectFeaturesViaWindowsArm(self: *ISASupport) bool {
        self.neon = std.os.windows.IsProcessorFeaturePresent(.ARM_NEON_INSTRUCTIONS_AVAILABLE);
        self.neon_fp16fma = std.os.windows.IsProcessorFeaturePresent(.ARM_FMAC_INSTRUCTIONS_AVAILABLE);
        self.neon_dotprod = std.os.windows.IsProcessorFeaturePresent(.ARM_V82_DP_INSTRUCTIONS_AVAILABLE);
        return true;
    }

    pub fn detectFeaturesViaAppleSilicon(self: *ISASupport) bool {
        self.neon = true;
        // Only NEON is guaranteed on most Apple Silicon devices.
        // Additional features (i.e., SME on M4) aren’t easily detectable afaik
        return true;
    }

    fn cpuid(eax: u32, ecx: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
        var a: u32 = undefined;
        var b: u32 = undefined;
        var c: u32 = undefined;
        var d: u32 = undefined;
        asm volatile (
            \\ cpuid
            : [a] "={eax}" (a),
              [b] "={ebx}" (b),
              [c] "={ecx}" (c),
              [d] "={edx}" (d),
            : [eax] "{eax}" (eax),
              [ecx] "{ecx}" (ecx),
            : .{ .memory = true });
        return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
    }

    fn cpuidXgetbv(index: u32) u64 {
        var eax: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile (
            \\ xgetbv
            : [a] "={eax}" (eax),
              [d] "={edx}" (edx),
            : [c] "{ecx}" (index),
        );
        return (@as(u64, edx) << 32) | eax;
    }

    fn detectFeaturesViaX86CpuId(self: *@This()) bool {
        const leaf1 = cpuid(1, 0);
        self.sse = (leaf1.edx & (1 << 25)) != 0;
        self.sse2 = (leaf1.edx & (1 << 26)) != 0;
        self.sse3 = (leaf1.ecx & (1 << 0)) != 0;
        self.ssse3 = (leaf1.ecx & (1 << 9)) != 0;
        self.sse4_1 = (leaf1.ecx & (1 << 19)) != 0;
        self.sse4_2 = (leaf1.ecx & (1 << 20)) != 0;
        const avx_bit = (leaf1.ecx & (1 << 28)) != 0;
        const fma_bit = (leaf1.ecx & (1 << 12)) != 0;

        if (avx_bit or fma_bit) {
            const xcr0 = cpuidXgetbv(0);
            const os_avx = (xcr0 & 0b110) == 0b110; // XMM+YMM enabled
            if (avx_bit and os_avx) self.avx = true;
            if (fma_bit and os_avx) self.fma = true;
        }

        const leaf7 = cpuid(7, 0);
        self.avx2 = (leaf7.ebx & (1 << 5)) != 0;
        self.avx512f = (leaf7.ebx & (1 << 16)) != 0;
        self.avx512dq = (leaf7.ebx & (1 << 17)) != 0;
        self.avx512cd = (leaf7.ebx & (1 << 28)) != 0;
        self.avx512bw = (leaf7.ebx & (1 << 30)) != 0;
        self.avx512vl = (leaf7.ebx & (1 << 31)) != 0;
        self.avx512vbmi = (leaf7.ecx & (1 << 1)) != 0;
        self.avx512vnni = (leaf7.ecx & (1 << 11)) != 0;
        self.avx512vbmi2 = (leaf7.ecx & (1 << 6)) != 0;
        self.avx512bitalg = (leaf7.ecx & (1 << 12)) != 0;
        self.avx512vpopcntdq = (leaf7.ecx & (1 << 14)) != 0;
        self.vaes = (leaf7.ecx & (1 << 9)) != 0;
        self.sha_ni = (leaf7.ebx & (1 << 29)) != 0;
        self.gfni = (leaf7.ecx & (1 << 8)) != 0;

        return true;
    }
};

test {
    const support = ISASupport.detect();
    std.debug.print("{any}\n", .{support});
}
