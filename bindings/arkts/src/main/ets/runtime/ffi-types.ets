export interface RustBuffer { capacity: bigint; len: bigint; data: bigint; }
export interface RustCallStatus { code: number; errorBuf?: Uint8Array; }
export const CALL_SUCCESS = 0;
export const CALL_ERROR = 1;
export const CALL_UNEXPECTED_ERROR = 2;
export const CALL_CANCELLED = 3;
