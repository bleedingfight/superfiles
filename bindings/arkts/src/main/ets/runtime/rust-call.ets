import { AbortError, RustPanic, UnexpectedRustCallError, UnexpectedRustCallStatusCode } from './errors';
import { CALL_CANCELLED, CALL_ERROR, CALL_SUCCESS, CALL_UNEXPECTED_ERROR, RustCallStatus } from './ffi-types';
export function checkRustCallStatus(status: RustCallStatus): void {
  switch (status.code) {
    case CALL_SUCCESS: return;
    case CALL_ERROR: throw new UnexpectedRustCallError();
    case CALL_UNEXPECTED_ERROR: throw new RustPanic('Rust panic');
    case CALL_CANCELLED: throw new AbortError();
    default: throw new UnexpectedRustCallStatusCode(status.code);
  }
}
