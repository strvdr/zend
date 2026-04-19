const std = @import("std");

// Packet types are intentionally few and ordered around the lifetime of a blob:
// metadata first, then zero or more chunks, then integrity, then done.

// Frame layout on disk / on the wire:
//
//   u32 frame_len (big-endian)
//   u8  packet_type
//   [ciphertext bytes]
//   [16-byte Poly1305 tag]
//
// frame_len includes everything after the length field.

// Chunk plaintext layout:
//
//   u32 chunk_index
//   u8  compression_flag
//   [payload bytes]
//
// The explicit chunk index makes the format easier to validate and debug even
// though the stream itself is delivered in order.

pub const METADATA: u8 = 0x03;
pub const CHUNK: u8 = 0x04;
pub const DONE: u8 = 0x05;
pub const INTEGRITY: u8 = 0x06;
pub const CHUNK_SIZE: usize = 64 * 1024;
pub const CHUNK_INDEX_SIZE: usize = 4;
pub const CHUNK_FLAG_SIZE: usize = 1;
pub const CHUNK_HEADER_SIZE: usize = CHUNK_INDEX_SIZE + CHUNK_FLAG_SIZE;
pub const TAG_SIZE: usize = 16;
pub const FRAME_LEN_SIZE: usize = 4;
pub const CONNECTION_ID_SIZE: usize = 4;

