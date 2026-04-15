const std = @import("std");

pub const METADATA: u8 = 0x03;
pub const CHUNK: u8 = 0x04;
pub const DONE: u8 = 0x05;

pub const CHUNK_SIZE: usize = 64 * 1024;
pub const CHUNK_HEADER_SIZE: usize = 4 + 1; // chunk_index(u32 LE) + compression_flag(u8)
pub const TAG_SIZE: usize = 16;
pub const FRAME_LEN_SIZE: usize = 4;
pub const CONNECTION_ID_SIZE: usize = 4;
