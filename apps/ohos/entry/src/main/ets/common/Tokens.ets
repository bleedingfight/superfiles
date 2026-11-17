/**
 * Design tokens — ArkTS port of design/tokens.json (the single source of truth
 * shared with Android's Colors.kt / Dimens.kt and iOS's Spacing.swift).
 *
 * Rule (docs/06-design-system.md): never hardcode a hex value in a view; pull
 * it from here. When Figma changes, tokens.json changes first, then this file.
 */

export interface Palette {
  surface: string;
  surfaceCard: string;
  surfaceTint: string;
  primary: string;
  primaryWarm: string;
  success: string;
  onSurface: string;
  onSurfaceVariant: string;
  onPrimary: string;
  outline: string;
  error: string;
  searchFieldBg: string;
  avatarBg: string;
  usageDeep: string;
  usageTrack: string;
  usageSegDocs: string;
  usageSegOther: string;
  pdfBadgeBg: string;
  pdfBadgeFg: string;
  sheetBadgeBg: string;
  docBadgeBg: string;
  errorContainer: string;
  divider: string;
}

export const LightPalette: Palette = {
  surface: '#F8F7F4',
  surfaceCard: '#FFFFFF',
  surfaceTint: '#EAF0F8',
  primary: '#466DA6',
  primaryWarm: '#A18460',
  success: '#6F8D7D',
  onSurface: '#292E35',
  onSurfaceVariant: '#777D86',
  onPrimary: '#FFFFFF',
  outline: '#A4A8AE',
  error: '#B3261E',
  searchFieldBg: '#F0EFEB',
  avatarBg: '#F0EBE3',
  usageDeep: '#304D76',
  usageTrack: '#D8E1ED',
  usageSegDocs: '#8CA6C8',
  usageSegOther: '#B4C0CF',
  pdfBadgeBg: '#F6ECE8',
  pdfBadgeFg: '#B7796E',
  sheetBadgeBg: '#EDF2ED',
  docBadgeBg: '#EAF0F8',
  errorContainer: '#F6ECE8',
  divider: '#EAE8E3'
};

export const DarkPalette: Palette = {
  surface: '#1A1916',
  surfaceCard: '#26231F',
  surfaceTint: '#22324A',
  primary: '#A9C3E6',
  primaryWarm: '#C7A87F',
  success: '#9CB8A9',
  onSurface: '#E7E5E1',
  onSurfaceVariant: '#A0A5AD',
  onPrimary: '#1A1916',
  outline: '#6A7078',
  error: '#F87171',
  searchFieldBg: '#26231F',
  avatarBg: '#33291F',
  usageDeep: '#D3E2F4',
  usageTrack: '#3B4148',
  usageSegDocs: '#7E98B9',
  usageSegOther: '#8E939A',
  pdfBadgeBg: '#3B2925',
  pdfBadgeFg: '#D9A198',
  sheetBadgeBg: '#26332A',
  docBadgeBg: '#22324A',
  errorContainer: '#3B2925',
  divider: '#33302B'
};

export function theme(dark: boolean): Palette {
  return dark ? DarkPalette : LightPalette;
}

/** 4-based spacing scale (dp). */
export const SPACE1: number = 4;
export const SPACE2: number = 8;
export const SPACE3: number = 12;
export const SPACE4: number = 16;
export const SPACE6: number = 24;
export const SPACE8: number = 32;
export const SCREEN_MARGIN: number = 24;
export const ROW_ICON_SLOT: number = 28;

/** Radius scale (dp). */
export const RADIUS_S: number = 10;
export const RADIUS_M: number = 14;
export const RADIUS_L: number = 20;
export const RADIUS_PILL: number = 999;

/** Type scale (fp). */
export const T_APPBAR: number = 17;
export const T_FILENAME: number = 14;
export const T_SECONDARY: number = 10;
export const T_CARD_TITLE: number = 12;
export const T_EMPTY_TITLE: number = 15;
export const T_EMPTY_BODY: number = 13;
export const T_BODY: number = 13;
