import util from '@ohos.util';

export class ByteWriter {
  private bytes: Array<number> = [];
  writeU8(value: number): void { this.bytes.push(value & 0xff); }
  writeI8(value: number): void { this.writeU8(value); }
  writeU16(value: number): void { this.writeU8(value >>> 8); this.writeU8(value); }
  writeI16(value: number): void { this.writeU16(value); }
  writeU32(value: number): void { this.writeU8(value >>> 24); this.writeU8(value >>> 16); this.writeU8(value >>> 8); this.writeU8(value); }
  writeI32(value: number): void { this.writeU32(value); }
  writeU64(value: bigint | number): void { const v = BigInt(value); this.writeU32(Number((v >> 32n) & 0xffffffffn)); this.writeU32(Number(v & 0xffffffffn)); }
  writeI64(value: bigint | number): void { this.writeU64(value); }
  writeF32(value: number): void { const b = new ArrayBuffer(4); new DataView(b).setFloat32(0, value, false); this.writeBytes(new Uint8Array(b)); }
  writeF64(value: number): void { const b = new ArrayBuffer(8); new DataView(b).setFloat64(0, value, false); this.writeBytes(new Uint8Array(b)); }
  writeBytes(value: Uint8Array): void { for (let i = 0; i < value.length; i++) { this.writeU8(value[i]); } }
  writeLengthPrefixedBytes(value: Uint8Array): void { this.writeI32(value.length); this.writeBytes(value); }
  finish(): Uint8Array { return new Uint8Array(this.bytes); }
}
export class ByteReader {
  private bytes: Uint8Array;
  private offset: number = 0;
  constructor(bytes: Uint8Array) { this.bytes = bytes; }
  readU8(): number { return this.bytes[this.offset++]; }
  readI8(): number { const v = this.readU8(); return v > 127 ? v - 256 : v; }
  readU16(): number { return (this.readU8() << 8) | this.readU8(); }
  readI16(): number { const v = this.readU16(); return v > 32767 ? v - 65536 : v; }
  readU32(): number { return ((this.readU8() << 24) >>> 0) + (this.readU8() << 16) + (this.readU8() << 8) + this.readU8(); }
  readI32(): number { const v = this.readU32(); return v > 2147483647 ? v - 4294967296 : v; }
  readU64(): bigint { const high = BigInt(this.readU32()); const low = BigInt(this.readU32()); return (high << 32n) | low; }
  readI64(): bigint { const high = BigInt(this.readU32()); const low = BigInt(this.readU32()); let v = (high << 32n) | low; if ((high & 0x80000000n) !== 0n) { v -= 1n << 64n; } return v; }
  readF32(): number { const b = this.readBytes(4); return new DataView(b.buffer, b.byteOffset, b.byteLength).getFloat32(0, false); }
  readF64(): number { const b = this.readBytes(8); return new DataView(b.buffer, b.byteOffset, b.byteLength).getFloat64(0, false); }
  readBytes(length: number): Uint8Array { const v = this.bytes.slice(this.offset, this.offset + length); this.offset += length; return v; }
  readLengthPrefixedBytes(): Uint8Array { return this.readBytes(this.readI32()); }
}
export class FfiConverterString {
  static lower(value: string): Uint8Array {
    const bytes = new util.TextEncoder().encodeInto(value);
    // HarmonyOS: encodeInto("") returns undefined; NAPI then fails with
    // "Get TypedArray info failed". Always hand it a real typed array.
    return bytes === undefined ? new Uint8Array(0) : bytes;
  }
  static lift(value: Uint8Array): string { return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeWithStream(value); }
}
export function writeUniffiTimestamp(writer: ByteWriter, value: Date): void {
  const millisNumber = value.getTime();
  if (!Number.isFinite(millisNumber)) { throw new Error('timestamp values must be valid Date instances.'); }
  const milliseconds = BigInt(Math.trunc(millisNumber));
  const negative = milliseconds < 0n;
  const magnitude = negative ? -milliseconds : milliseconds;
  const seconds = magnitude / 1000n;
  const nanos = Number((magnitude % 1000n) * 1000000n);
  writer.writeI64(negative ? -seconds : seconds);
  writer.writeU32(nanos);
}
export function readUniffiTimestamp(reader: ByteReader): Date {
  const seconds = reader.readI64();
  const nanos = reader.readU32();
  const magnitudeMs = (seconds < 0n ? -seconds : seconds) * 1000n + BigInt(Math.floor(nanos / 1000000));
  return new Date(seconds < 0n ? -Number(magnitudeMs) : Number(magnitudeMs));
}
export function writeUniffiDuration(writer: ByteWriter, value: number): void {
  if (!Number.isFinite(value) || value < 0 || value !== Math.trunc(value)) { throw new Error('duration values must be non-negative integer millisecond counts.'); }
  const milliseconds = BigInt(value);
  writer.writeU64(milliseconds / 1000n);
  writer.writeU32(Number((milliseconds % 1000n) * 1000000n));
}
export function readUniffiDuration(reader: ByteReader): number {
  const seconds = reader.readU64();
  const nanos = reader.readU32();
  return Number(seconds * 1000n) + nanos / 1000000;
}
export async function __arktsAwaitNative<T>(promise: Promise<T>): Promise<T> {
  const value = await promise;
  await Promise.resolve();
  return value;
}
const UNIFFI_ERROR_HEX_PREFIX = 'UNIFFI_ERROR_HEX:';
function __arktsErrorMessage(error: unknown): string {
  if (error instanceof Error) { return error.message; }
  return String(error);
}
function __arktsDecodeHexBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) { throw new Error('invalid UniFFI error buffer encoding'); }
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    const value = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(value)) { throw new Error('invalid UniFFI error buffer encoding'); }
    bytes[i] = value;
  }
  return bytes;
}
export function __arktsRethrowNativeError<T extends Error>(error: unknown, liftError: (bytes: Uint8Array) => T): never {
  const message = __arktsErrorMessage(error);
  const index = message.indexOf(UNIFFI_ERROR_HEX_PREFIX);
  if (index >= 0) {
    throw liftError(__arktsDecodeHexBytes(message.slice(index + UNIFFI_ERROR_HEX_PREFIX.length)));
  }
  throw error;
}
