"""Re-inject the generic `mountCloud` export into the generated ArkTS bindings.

`uniffi-bindgen-arkts` cannot be run here (custom patched fork), so the
HarmonyOS bindings are generated elsewhere and this method is added by hand.
Running this after a regeneration restores it; it is a no-op when present.
"""

def patch_native():
    p = 'bindings/arkts/native/src/lib.rs'
    s = open(p, encoding='utf-8').read()
    if 'MountCloud' in s:
        return
    start = s.index('#[napi(js_name = "uniffiSuperfilesFnMethodSuperfilesMountDropbox")]')
    end = s.index('#[napi(js_name = "uniffiSuperfilesFnMethodSuperfilesMountGoogleDrive")]')
    block = s[start:end]
    cloud = (block
             .replace('MountDropbox', 'MountCloud')
             .replace('mount_dropbox', 'mount_cloud')
             .replace('ptr: napi_ohos::bindgen_prelude::BigInt, ',
                      'ptr: napi_ohos::bindgen_prelude::BigInt, provider: napi_ohos::bindgen_prelude::Uint8Array, ')
             .replace('fn __arkts_ffi(ptr: u64, ',
                      'fn __arkts_ffi(ptr: u64, provider: RustBuffer, ')
             .replace('let label_ffi =',
                      'let provider_ffi = rustbuffer_from_bytes(provider.as_ref())?;    let label_ffi =')
             .replace('__arkts_ffi(ptr_ffi, ', '__arkts_ffi(ptr_ffi, provider_ffi, '))
    assert 'provider_ffi' in cloud
    open(p, 'w', encoding='utf-8').write(s[:end] + cloud + s[end:])


def patch_ets():
    p = 'bindings/arkts/src/main/ets/superfiles-arkts.ets'
    s = open(p, encoding='utf-8').read()
    if 'mountCloud(' in s:
        return
    anchor = '  mountDropbox(label: string, accessToken: string, refreshToken: string, clientId: string, clientSecret: string): string {'
    wrapper = '''  mountCloud(provider: string, label: string, accessToken: string, refreshToken: string, clientId: string, clientSecret: string): string {
    try {
      return __arktsLiftString(native.uniffiSuperfilesFnMethodSuperfilesMountCloud(this.uniffiHandle(), __arktsLowerString(provider), __arktsLowerString(label), __arktsLowerString(accessToken), __arktsLowerString(refreshToken), __arktsLowerString(clientId), __arktsLowerString(clientSecret))) as string;
    } catch (error) {
      __arktsRethrowNativeError(error, __arktsLiftSfError);
    }
  }

'''
    assert anchor in s
    open(p, 'w', encoding='utf-8').write(s.replace(anchor, wrapper + anchor, 1))


def patch_dts():
    p = 'bindings/arkts/src/main/ets/superfiles-arkts.d.ts'
    s = open(p, encoding='utf-8').read()
    if 'mountCloud(' in s:
        return
    anchor = '  mountDropbox(label: string, accessToken: string, refreshToken: string, clientId: string, clientSecret: string): string;'
    line = '  mountCloud(provider: string, label: string, accessToken: string, refreshToken: string, clientId: string, clientSecret: string): string;'
    assert anchor in s
    open(p, 'w', encoding='utf-8').write(s.replace(anchor, line + '\n' + anchor, 1))


patch_native()
patch_ets()
patch_dts()
print('ArkTS mountCloud patch applied')
