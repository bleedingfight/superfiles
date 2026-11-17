import { theme, Palette, RADIUS_S, T_SECONDARY } from './Tokens';

/**
 * Type-coloured badge, mirroring Android's FileIcon (badge bg/fg pairs come
 * straight from tokens.json). Folders get the primary tint.
 */
function categoryOf(name: string, isDir: boolean): string {
  if (isDir) {
    return 'dir';
  }
  const n: string = name.toLowerCase();
  const dot: number = n.lastIndexOf('.');
  const ext: string = dot >= 0 ? n.substring(dot + 1) : '';
  if (ext === 'pdf') {
    return 'pdf';
  }
  if (/^(jpg|jpeg|png|gif|webp|bmp|heic|heif)$/.test(ext)) {
    return 'image';
  }
  if (/^(mp4|mkv|mov|webm|m4v|avi)$/.test(ext)) {
    return 'video';
  }
  if (/^(mp3|flac|wav|aac|m4a|ogg)$/.test(ext)) {
    return 'audio';
  }
  if (/^(zip|7z|rar|tar|gz|bz2|xz)$/.test(ext)) {
    return 'archive';
  }
  if (/^(doc|docx|xls|xlsx|ppt|pptx|txt|md|csv|rtf)$/.test(ext)) {
    return 'doc';
  }
  if (/^(rs|kt|ets|ts|js|py|sh|json|toml|yaml|yml|xml|html|css|c|h|cpp)$/.test(ext)) {
    return 'code';
  }
  return 'other';
}

function badgeLabel(name: string, isDir: boolean): string {
  if (isDir) {
    return 'DIR';
  }
  const dot: number = name.lastIndexOf('.');
  if (dot < 0 || dot === name.length - 1) {
    return 'FILE';
  }
  const ext: string = name.substring(dot + 1);
  return ext.length > 4 ? ext.substring(0, 4) : ext;
}

@Component
export struct FileIcon {
  @Prop name: string;
  @Prop isDir: boolean;
  @Prop dark: boolean = false;
  @Prop box: number = 36;

  private bg(p: Palette): string {
    const c: string = categoryOf(this.name, this.isDir);
    if (c === 'dir') {
      return p.surfaceTint;
    }
    if (c === 'pdf') {
      return p.pdfBadgeBg;
    }
    if (c === 'doc') {
      return p.docBadgeBg;
    }
    if (c === 'archive') {
      return p.sheetBadgeBg;
    }
    if (c === 'code') {
      return p.avatarBg;
    }
    return p.searchFieldBg;
  }

  private fg(p: Palette): string {
    const c: string = categoryOf(this.name, this.isDir);
    if (c === 'dir') {
      return p.primary;
    }
    if (c === 'pdf') {
      return p.pdfBadgeFg;
    }
    if (c === 'doc') {
      return p.primary;
    }
    if (c === 'archive') {
      return p.success;
    }
    if (c === 'code') {
      return p.primaryWarm;
    }
    if (c === 'image' || c === 'video') {
      return p.primary;
    }
    return p.onSurfaceVariant;
  }

  build() {
    Column() {
      Text(badgeLabel(this.name, this.isDir))
        .fontSize(T_SECONDARY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.fg(theme(this.dark)))
        .maxLines(1)
    }
    .width(this.box)
    .height(this.box)
    .borderRadius(RADIUS_S)
    .backgroundColor(this.bg(theme(this.dark)))
    .justifyContent(FlexAlign.Center)
  }
}
