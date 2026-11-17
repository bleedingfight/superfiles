"""Re-inject the `mountS3` export into the generated ArkTS bindings.

Same situation as `mountCloud`: the ArkTS generator is a pinned custom fork that
cannot be run here, so the method is patched in after generation. Idempotent.
"""

NATIVE = '''#[napi(js_name = "uniffiSuperfilesFnMethodSuperfilesMountS3")]
pub fn uniffi_superfiles_fn_method_superfiles_mount_s3(ptr: napi_ohos::bindgen_prelude::BigInt, label: napi_ohos::bindgen_prelude::Uint8Array, endpoint: napi_ohos::bindgen_prelude::Uint8Array, region: napi_ohos::bindgen_prelude::Uint8Array, bucket: napi_ohos::bindgen_prelude::Uint8Array, access_key: napi_ohos::bindgen_prelude::Uint8Array, secret_key: napi_ohos::bindgen_prelude::Uint8Array, session_token: napi_ohos::bindgen_prelude::Uint8Array, path_style: bool) -> napi_ohos::Result<napi_ohos::bindgen_prelude::Uint8Array> {
    unsafe extern "C" {
        #[link_name = "uniffi_superfiles_fn_method_superfiles_mount_s3"]
        fn __arkts_ffi(ptr: u64, label: RustBuffer, endpoint: RustBuffer, region: RustBuffer, bucket: RustBuffer, access_key: RustBuffer, secret_key: RustBuffer, session_token: RustBuffer, path_style: i8, call_status: &mut RustCallStatus) -> RustBuffer;
    }
    let ptr_ffi = bigint_to_u64(ptr, "ptr")?;    let label_ffi = rustbuffer_from_bytes(label.as_ref())?;    let endpoint_ffi = rustbuffer_from_bytes(endpoint.as_ref())?;    let region_ffi = rustbuffer_from_bytes(region.as_ref())?;    let bucket_ffi = rustbuffer_from_bytes(bucket.as_ref())?;    let access_key_ffi = rustbuffer_from_bytes(access_key.as_ref())?;    let secret_key_ffi = rustbuffer_from_bytes(secret_key.as_ref())?;    let session_token_ffi = rustbuffer_from_bytes(session_token.as_ref())?;

    let mut call_status = RustCallStatus::default();

    let ffi_result = unsafe { __arkts_ffi(ptr_ffi, label_ffi, endpoint_ffi, region_ffi, bucket_ffi, access_key_ffi, secret_key_ffi, session_token_ffi, if path_style { 1 } else { 0 }, &mut call_status) };

    check_call_status(&mut call_status)?;

    Ok(napi_ohos::bindgen_prelude::Uint8Array::from(ffi_result.destroy_into_vec()))

}'''

ETS = '''  mountS3(label: string, endpoint: string, region: string, bucket: string, accessKey: string, secretKey: string, sessionToken: string, pathStyle: boolean): string {
    try {
      return __arktsLiftString(native.uniffiSuperfilesFnMethodSuperfilesMountS3(this.uniffiHandle(), __arktsLowerString(label), __arktsLowerString(endpoint), __arktsLowerString(region), __arktsLowerString(bucket), __arktsLowerString(accessKey), __arktsLowerString(secretKey), __arktsLowerString(sessionToken), pathStyle)) as string;
    } catch (error) {
      __arktsRethrowNativeError(error, __arktsLiftSfError);
    }
  }

'''

DTS = '  mountS3(label: string, endpoint: string, region: string, bucket: string, accessKey: string, secretKey: string, sessionToken: string, pathStyle: boolean): string;'


def patch(path, needle, anchor, insert, before=True):
    s = open(path, encoding='utf-8').read()
    if needle in s:
        return
    idx = s.index(anchor)
    s = s[:idx] + insert + s[idx:]
    open(path, 'w', encoding='utf-8').write(s)


patch(
    'bindings/arkts/native/src/lib.rs',
    'MountS3',
    '#[napi(js_name = "uniffiSuperfilesFnMethodSuperfilesMountSftp")]',
    NATIVE,
)
patch(
    'bindings/arkts/src/main/ets/superfiles-arkts.ets',
    'mountS3(',
    '  mountSftp(label: string, host: string, port: number, username: string, password: string): string {',
    ETS,
)
patch(
    'bindings/arkts/src/main/ets/superfiles-arkts.d.ts',
    'mountS3(',
    '  mountSftp(label: string, host: string, port: number, username: string, password: string): string;',
    DTS + '\n',
)
print('ArkTS mountS3 patch applied')
