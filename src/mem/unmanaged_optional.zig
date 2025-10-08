/// Unmanaged Optional Type
/// This is a simple implementation of an optional type.
/// This was implemented due to builtin `?T` having undeclared alignment issues.
pub fn Optional(comptime T: type) type {
    return packed struct {
        is_some: bool,
        value: T,
        pub fn none() Optional(T) {
            return Optional(T){ .is_some = false, .value = undefined };
        }
        pub fn wrap(value: T) Optional(T) {
            return Optional(T){ .is_some = true, .value = value };
        }
        pub fn unwrap(self: Optional(T)) T {
            if (!self.is_some) {
                unreachable("Attempted to unwrap None");
            }
            return self.value;
        }
    };
}
pub const OptionalU32 = Optional(u32);
