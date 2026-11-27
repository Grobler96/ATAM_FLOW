export interface Rect { x: number; y: number; w: number; h: number }
export interface Cam { s: number; tx: number; ty: number }
export interface Pop { kind: string; t: number; on?: string; rect?: string; text?: string; icon?: string; at?: [number, number]; tone?: string; from?: string; corner?: string; keys?: string[] }
export interface Word { w: string; t0: number; t1: number }
export interface Step { key: string; shot: string; zoom: string | null; start: number; voice: number; end: number; words: Word[]; pops: Pop[] }
export interface Timing { intro: number; outro: number; total: number; steps: Step[] }
export interface ShotInfo { file: string; rects: Record<string, Rect> }
