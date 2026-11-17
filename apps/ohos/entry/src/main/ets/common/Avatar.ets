/**
 * 头像字/缩写规则（两端统一契约）：
 * - 拉丁字母开头：取首字母大写 —— Tony → T、bruce → B；
 * - 其余文字（中文等）：取最后一个字符 —— 刘帅 → 帅（称呼感）；
 * - 空昵称：回退 'S'（superfiles）。
 * 与 Android VfsViewModel.avatarCharOf 保持同一行为。
 */
export function avatarCharOf(name: string): string {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) {
    return 'S';
  }
  const code: number = trimmed.charCodeAt(0);
  if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
    return code >= 97 ? String.fromCharCode(code - 32) : trimmed.substring(0, 1);
  }
  return trimmed.substring(trimmed.length - 1);
}
