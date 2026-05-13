const std = @import("std");

// ===== FLOAT OPERATIONS (f32) =====

pub inline fn addF32(a: f32, b: f32) f32 {
    // addss: Scalar Single-Precision Addition
    return asm (
        \\ addss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> f32),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : .{ .cc = true }
    );
}

pub inline fn subF32(a: f32, b: f32) f32 {
    // subss: Scalar Single-Precision Subtraction
    return asm (
        \\ subss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> f32),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : .{ .cc = true }
    );
}

pub inline fn mulF32(a: f32, b: f32) f32 {
    // mulss: Scalar Single-Precision Multiplication
    return asm (
        \\ mulss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> f32),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : .{ .cc = true }
    );
}

pub inline fn divF32(a: f32, b: f32) f32 {
    // divss: Scalar Single-Precision Division
    return asm (
        \\ divss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> f32),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : .{ .cc = true }
    );
}

pub inline fn minF32(a: f32, b: f32) f32 {
    // minss: Scalar Single-Precision Minimum
    return asm (
        \\ minss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> f32),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : .{ .cc = true }
    );
}

pub inline fn maxF32(a: f32, b: f32) f32 {
    // maxss: Scalar Single-Precision Maximum
    return asm (
        \\ maxss %xmm1, %xmm0
        : [ret] "={xmm0}" (-> f32),
        : [a] "{xmm0}" (a),
          [b] "{xmm1}" (b),
        : .{ .cc = true }
    );
}

// ===== U64 OPERATIONS =====

pub inline fn addU64(a: u64, b: u64) u64 {
    // add: 64-bit Integer Addition (sets carry flag on overflow)
    return asm (
        \\ add %rbx, %rax
        : [ret] "={rax}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .cc = true }
    );
}

pub inline fn subU64(a: u64, b: u64) u64 {
    // sub: 64-bit Integer Subtraction (sets borrow flag on underflow)
    return asm (
        \\ sub %rbx, %rax
        : [ret] "={rax}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .cc = true }
    );
}

pub inline fn mulU64(a: u64, b: u64) u64 {
    // mul: 64-bit Unsigned Multiply
    // Result in rdx:rax, we only keep lower 64 bits (wrapping behavior)
    return asm (
        \\ mul %rbx
        : [ret] "={rax}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .rdx = true, .cc = true }
    );
}

pub inline fn divU64(a: u64, b: u64) u64 {
    // div: 64-bit Unsigned Division
    // rdx:rax / rbx = quotient in rax, remainder in rdx
    return asm (
        \\ xor %rdx, %rdx    // Clear upper 64 bits
        \\ div %rbx
        : [ret] "={rax}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .rdx = true, .cc = true }
    );
}

pub inline fn modU64(a: u64, b: u64) u64 {
    // mod: 64-bit Unsigned Remainder (same as div, but return remainder)
    return asm (
        \\ xor %rdx, %rdx    // Clear upper 64 bits
        \\ div %rbx
        : [ret] "={rdx}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .rax = true, .cc = true }
    );
}

pub inline fn minU64(a: u64, b: u64) u64 {
    // No single min instruction for integers, use cmp + cmov
    return asm (
        \\ cmp %rbx, %rax
        \\ cmovb %rbx, %rax   // Move if below (b < a)
        : [ret] "={rax}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .cc = true }
    );
}

pub inline fn maxU64(a: u64, b: u64) u64 {
    // No single max instruction for integers, use cmp + cmov
    return asm (
        \\ cmp %rbx, %rax
        \\ cmova %rbx, %rax   // Move if above (b > a)
        : [ret] "={rax}" (-> u64),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .cc = true }
    );
}

// ===== U128 OPERATIONS =====

pub inline fn addU128(a: u128, b: u128) u128 {
    // u128 is stored in two 64-bit registers: rdx:rax
    return asm (
        \\ add %rbx, %rax     // Add lower 64 bits
        \\ adc %rcx, %rdx     // Add upper 64 bits with carry
        : [ret] "={rax}" (-> u128),  // Return in rdx:rax
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
          [b_hi] "{rcx}" (@intCast(b >> 64)),
        : .{ .rdx = true, .cc = true }
    );
}

pub inline fn subU128(a: u128, b: u128) u128 {
    // Similar to add, but with borrow
    return asm (
        \\ sub %rbx, %rax     // Subtract lower 64 bits
        \\ sbb %rcx, %rdx     // Subtract upper 64 bits with borrow
        : [ret] "={rax}" (-> u128),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
          [b_hi] "{rcx}" (@intCast(b >> 64)),
        : .{ .rdx = true, .cc = true }
    );
}

pub inline fn mulU128(a: u128, b: u128) u128 {
    // For u128 multiplication, we need to handle overflow carefully
    // This is a simplified version that keeps only lower 128 bits
    return asm (
        \\ mul %rbx           // rdx:rax = rax * rbx (lower 64 * lower 64)
        \\ mov %rax, %rsi     // Save lower result
        \\ mov %rdx, %rdi     // Save upper result
        \\ mov %rcx, %rax     // Load a's upper half
        \\ mul %rbx           // rdx:rax = a_hi * b_lo
        \\ add %rax, %rdi     // Add to upper result
        \\ mov %rsi, %rax     // Restore lower result
        \\ mov %rdi, %rdx     // Restore upper result
        : [ret] "={rax}" (-> u128),
        : [a] "{rax}" (@intCast(a)),
          [b] "{rbx}" (@intCast(b)),
          [a_hi] "{rcx}" (@intCast(a >> 64)),
        : .{ .rdx = true, .rsi = true, .rdi = true, .cc = true }
    );
}

// ===== USIZE OPERATIONS =====

// usize is just an alias for the target's pointer size
// On x86_64, it's the same as u64
pub inline fn addUsize(a: usize, b: usize) usize {
    return asm (
        \\ add %rbx, %rax
        : [ret] "={rax}" (-> usize),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .cc = true }
    );
}

pub inline fn subUsize(a: usize, b: usize) usize {
    return asm (
        \\ sub %rbx, %rax
        : [ret] "={rax}" (-> usize),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .cc = true }
    );
}

pub inline fn mulUsize(a: usize, b: usize) usize {
    return asm (
        \\ mul %rbx
        : [ret] "={rax}" (-> usize),
        : [a] "{rax}" (a),
          [b] "{rbx}" (b),
        : .{ .rdx = true, .cc = true }
    );
}
