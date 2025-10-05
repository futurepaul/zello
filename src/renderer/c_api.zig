// Shared C API import
// This ensures all modules use the same C types

pub const c = @cImport({
    @cInclude("mcore.h");
});
