export class RustPanic extends Error {}
export class AbortError extends Error {}
export class UnexpectedRustCallError extends Error {}
export class UnexpectedRustCallStatusCode extends Error {
  readonly code: number;
  constructor(code: number) { super(`Unexpected Rust call status ${code}`); this.code = code; }
}
