#!/usr/bin/env node
// ============================================================================
// gen-chart.mjs — 从 perf.md §4 的四张结果表，为每个用例生成一张 2×2 柱状图
//
// 用法（任意目录均可，路径相对脚本位置解析）:
//   node scripts/perf/gen-chart.mjs
//
// 输出: scripts/perf/charts/perf-P1.svg … perf-P4.svg（每用例一张，嵌入各自章节）
//   2×2 四格 ＝ 该用例的四项时延指标（左上首字平均 / 右上端到端平均 /
//   左下首字最大 / 右下端到端最大），每格 5 组配置（1×1、1×2、1×3、2×2、3×3）
//   柱状图，柱顶标数值，横轴＝算力数×聊天并发数。
//
//   y 轴刻度按「指标」全局统一（四张图共用：首字 0–25s、端到端 0–100s，
//   随数据自适应取整），因此各章节图的柱高可跨用例直接对比。
//
// perf.md §4 表格数据更新后重跑本脚本即可同步图表，无需手改。
// 依赖: 仅 node 本身，无第三方包。
// ============================================================================
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const DIR = path.dirname(fileURLToPath(import.meta.url)); // scripts/perf/
const MD_PATH = path.join(DIR, 'perf.md');
const OUT_DIR = path.join(DIR, 'charts');

// ---------- 1. 解析 perf.md §4：每个 "### 4.x 标题" 后的第一张表格 ----------
function parseTables(md) {
  const lines = md.split('\n');
  const cases = [];
  let cur = null;
  for (let i = 0; i < lines.length; i++) {
    const h = lines[i].match(/^### 4\.(\d)\s+(.*)$/);
    if (h) {
      cur = { p: 'P' + h[1], title: h[2].trim(), rows: [] };
      cases.push(cur);
      continue;
    }
    if (cur && lines[i].startsWith('|') && lines[i].includes('首字平均时延')) {
      // 表头下一行是 |---| 分隔行，其后连续的 |...| 行是数据
      for (let j = i + 2; j < lines.length && lines[j].startsWith('|'); j++) {
        const cells = lines[j].split('|').map(s => s.trim()).filter(s => s !== '');
        if (cells.length >= 6) {
          cur.rows.push({ label: cells[0] + '×' + cells[1], v: cells.slice(2, 6).map(Number) });
        }
      }
      cur = null;
    }
  }
  return cases.filter(c => c.rows.length > 0);
}

// ---------- 2. 布局与样式常量 ----------
const METRICS = ['首字平均时延', '端到端平均时延', '首字最大时延', '端到端最大时延'];
// 首字＝蓝系、端到端＝橙系；平均＝深色、最大＝浅色
const COLORS = ['#3565a7', '#d9782d', '#8fb3dd', '#f2bd8f'];
const FONT = '-apple-system, PingFang SC, Hiragino Sans GB, Microsoft YaHei, sans-serif';

// 向上取整到「好看」的刻度上限（1/1.2/1.6/2/2.5/… × 10^n）
function niceCeil(m) {
  const pow = Math.pow(10, Math.floor(Math.log10(m)));
  for (const f of [1, 1.2, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10]) {
    if (f * pow >= m) return f * pow;
  }
  return 10 * pow;
}
const fmtTick = v => (Number.isInteger(v) ? String(v) : v.toFixed(0));
const fmtVal = v => v.toFixed(1);

// ---------- 3. SVG 生成 ----------
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function makeText(add) {
  return function text(x, y, str, o = {}) {
    const { size = 12, fill = '#333', anchor = 'middle', weight = 400 } = o;
    add(`<text x="${x}" y="${y}" font-family="${FONT}" font-size="${size}" fill="${fill}" text-anchor="${anchor}" font-weight="${weight}">${esc(str)}</text>`);
  };
}

// 单个指标面板：标题 + y 刻度 + 网格 + 柱 + 柱顶数值 + 组标签（全部自带，独立可读）
function panel(add, text, px, py, pw, ph, rows, mi, scale) {
  const titleH = 26, innerL = 46, innerT = 14, innerB = 32, innerR = 10;
  const x0 = px + innerL, y0 = py + titleH + innerT;
  const plotW = pw - innerL - innerR, plotH = ph - titleH - innerT - innerB;
  const yBase = y0 + plotH;

  text(px + pw / 2, py + 18, METRICS[mi], { size: 15, fill: '#222', weight: 600 });

  const ticks = 5;
  for (let t = 0; t <= ticks; t++) {
    const y = yBase - plotH * t / ticks;
    add(`<line x1="${x0}" y1="${y}" x2="${x0 + plotW}" y2="${y}" stroke="${t === 0 ? '#888' : '#e6e6e6'}" stroke-width="${t === 0 ? 1.2 : 1}"/>`);
    text(x0 - 8, y + 4, fmtTick(scale * t / ticks), { size: 10.5, fill: '#777', anchor: 'end' });
  }

  const slot = plotW / rows.length;
  const barW = Math.min(48, slot * 0.58);
  rows.forEach((r, i) => {
    const v = r.v[mi];
    const h = Math.max(0, plotH * v / scale);
    const bx = x0 + slot * i + (slot - barW) / 2;
    add(`<rect x="${bx.toFixed(1)}" y="${(yBase - h).toFixed(1)}" width="${barW.toFixed(1)}" height="${h.toFixed(1)}" fill="${COLORS[mi]}" stroke="#fff" stroke-width="0.6" rx="1.5"/>`);
    text(bx + barW / 2, yBase - h - 5, fmtVal(v), { size: 12, fill: '#444' });
    text(x0 + slot * i + slot / 2, yBase + 21, r.label, { size: 13, fill: '#333' });
  });
}

function main() {
  const cases = parseTables(readFileSync(MD_PATH, 'utf8'));
  if (cases.length !== 4) {
    console.error(`错误: 期望解析到 4 个用例表格，实际 ${cases.length} 个（检查 perf.md §4 的 "### 4.x" 标题与表格格式）`);
    process.exit(1);
  }

  // 每项指标的刻度在全部用例间统一（柱高可跨章节对比）
  const colScale = METRICS.map((_, mi) =>
    niceCeil(Math.max(...cases.flatMap(c => c.rows.map(r => r.v[mi])))));

  // 单张图：2×2 面板
  const W = 960, H = 700;
  const M = { left: 14, right: 18, top: 50, bottom: 12, gapX: 20, gapY: 16 };
  const panelW = (W - M.left - M.right - M.gapX) / 2;
  const panelH = (H - M.top - M.bottom - M.gapY) / 2;

  mkdirSync(OUT_DIR, { recursive: true });
  for (const c of cases) {
    const parts = [];
    const add = s => parts.push(s);
    const text = makeText(add);

    add(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`);
    add(`<rect width="${W}" height="${H}" fill="#ffffff"/>`);
    text(W / 2, 32, `${c.p} ${c.title}：四项时延指标（单位 s）`, { size: 20, fill: '#222', weight: 700 });

    for (let mi = 0; mi < 4; mi++) {
      const col = mi % 2, row = Math.floor(mi / 2);
      panel(add, text, M.left + col * (panelW + M.gapX), M.top + row * (panelH + M.gapY),
        panelW, panelH, c.rows, mi, colScale[mi]);
    }

    add('</svg>');
    const out = path.join(OUT_DIR, `perf-${c.p}.svg`);
    writeFileSync(out, parts.join('\n'));
    console.log(`OK: ${c.p} ${c.title} → ${out}`);
  }
  console.log(`    指标刻度（四图统一）: ${METRICS.map((m, i) => `${m} 0–${colScale[i]}s`).join('；')}`);
}

main();
