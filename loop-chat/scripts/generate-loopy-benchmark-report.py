#!/usr/bin/env python3
"""Generate the monochrome Loopy single-vs-dual benchmark summary PDF."""

from __future__ import annotations

import csv
import json
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    LongTable,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_ROOT = REPO_ROOT / "benchmark_artifacts" / "bfcl_20260811"
OUTPUT_DIR = REPO_ROOT / "output" / "pdf"
OUTPUT_PATH = OUTPUT_DIR / "Loopy_单双设备协同推理测试汇总_20260812.pdf"

FONT_REGULAR_PATH = "/System/Library/Fonts/STHeiti Light.ttc"
FONT_BOLD_PATH = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_REGULAR = "LoopyHeitiLight"
FONT_BOLD = "LoopyHeitiMedium"

PAGE_SIZE = landscape(A4)
PAGE_WIDTH, PAGE_HEIGHT = PAGE_SIZE
LEFT_MARGIN = 10 * mm
RIGHT_MARGIN = 10 * mm
TOP_MARGIN = 9 * mm
BOTTOM_MARGIN = 11 * mm
CONTENT_WIDTH = PAGE_WIDTH - LEFT_MARGIN - RIGHT_MARGIN


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def seconds(value: str | int | float | None) -> str:
    if value in (None, ""):
        return "-"
    return f"{float(value) / 1000:.3f}"


def number(value: str | int | float | None) -> str:
    if value in (None, ""):
        return "-"
    return str(int(float(value)))


def register_fonts() -> None:
    pdfmetrics.registerFont(TTFont(FONT_REGULAR, FONT_REGULAR_PATH, subfontIndex=0))
    pdfmetrics.registerFont(TTFont(FONT_BOLD, FONT_BOLD_PATH, subfontIndex=0))


def build_styles() -> dict[str, ParagraphStyle]:
    base = getSampleStyleSheet()
    styles = {
        "title": ParagraphStyle(
            "ReportTitle",
            parent=base["Title"],
            fontName=FONT_BOLD,
            fontSize=21,
            leading=25,
            alignment=TA_LEFT,
            textColor=colors.black,
            spaceAfter=2.5 * mm,
            wordWrap="CJK",
        ),
        "subtitle": ParagraphStyle(
            "ReportSubtitle",
            parent=base["Normal"],
            fontName=FONT_REGULAR,
            fontSize=9.8,
            leading=13,
            textColor=colors.black,
            spaceAfter=2.5 * mm,
            wordWrap="CJK",
        ),
        "h1": ParagraphStyle(
            "HeadingOne",
            parent=base["Heading1"],
            fontName=FONT_BOLD,
            fontSize=13.2,
            leading=16,
            textColor=colors.black,
            spaceBefore=1.5 * mm,
            spaceAfter=2.2 * mm,
            keepWithNext=True,
            wordWrap="CJK",
        ),
        "h2": ParagraphStyle(
            "HeadingTwo",
            parent=base["Heading2"],
            fontName=FONT_BOLD,
            fontSize=9.6,
            leading=12,
            textColor=colors.black,
            spaceBefore=1.8 * mm,
            spaceAfter=1.2 * mm,
            keepWithNext=True,
            wordWrap="CJK",
        ),
        "body": ParagraphStyle(
            "Body",
            parent=base["BodyText"],
            fontName=FONT_REGULAR,
            fontSize=8.2,
            leading=11.2,
            textColor=colors.black,
            spaceAfter=1.2 * mm,
            wordWrap="CJK",
        ),
        "body_bold": ParagraphStyle(
            "BodyBold",
            parent=base["BodyText"],
            fontName=FONT_BOLD,
            fontSize=8.2,
            leading=11.2,
            textColor=colors.black,
            spaceAfter=1.2 * mm,
            wordWrap="CJK",
        ),
        "small": ParagraphStyle(
            "Small",
            parent=base["BodyText"],
            fontName=FONT_REGULAR,
            fontSize=6.9,
            leading=8.8,
            textColor=colors.black,
            wordWrap="CJK",
        ),
        "small_bold": ParagraphStyle(
            "SmallBold",
            parent=base["BodyText"],
            fontName=FONT_BOLD,
            fontSize=6.9,
            leading=8.8,
            textColor=colors.black,
            wordWrap="CJK",
        ),
        "table": ParagraphStyle(
            "TableCell",
            parent=base["BodyText"],
            fontName=FONT_REGULAR,
            fontSize=6.8,
            leading=8.4,
            textColor=colors.black,
            wordWrap="CJK",
        ),
        "table_first": ParagraphStyle(
            "TableFirstCell",
            parent=base["BodyText"],
            fontName=FONT_BOLD,
            fontSize=6.8,
            leading=8.4,
            textColor=colors.black,
            wordWrap="CJK",
        ),
        "table_right": ParagraphStyle(
            "TableRightCell",
            parent=base["BodyText"],
            fontName=FONT_REGULAR,
            fontSize=6.8,
            leading=8.4,
            alignment=2,
            textColor=colors.black,
            wordWrap="CJK",
        ),
        "table_center": ParagraphStyle(
            "TableCenterCell",
            parent=base["BodyText"],
            fontName=FONT_REGULAR,
            fontSize=6.8,
            leading=8.4,
            alignment=TA_CENTER,
            textColor=colors.black,
            wordWrap="CJK",
        ),
        "table_header": ParagraphStyle(
            "TableHeader",
            parent=base["BodyText"],
            fontName=FONT_BOLD,
            fontSize=6.8,
            leading=8.4,
            alignment=TA_CENTER,
            textColor=colors.white,
            wordWrap="CJK",
        ),
        "note": ParagraphStyle(
            "Note",
            parent=base["BodyText"],
            fontName=FONT_REGULAR,
            fontSize=6.9,
            leading=9,
            leftIndent=0,
            borderWidth=0.5,
            borderColor=colors.black,
            borderPadding=2.5,
            spaceBefore=1 * mm,
            spaceAfter=1.2 * mm,
            wordWrap="CJK",
        ),
    }
    return styles


def p(text: str, style: ParagraphStyle) -> Paragraph:
    return Paragraph(text, style)


def bullet(text: str, styles: dict[str, ParagraphStyle]) -> Paragraph:
    return p(f"- {text}", styles["body"])


def table_cell(text: object, style: ParagraphStyle) -> Paragraph:
    value = "-" if text is None or str(text) == "" else str(text)
    return p(value, style)


def make_table(
    rows: list[list[object]],
    widths: list[float],
    styles: dict[str, ParagraphStyle],
    repeat_rows: int = 1,
    alignments: dict[int, str] | None = None,
) -> LongTable:
    alignment_map = alignments or {}
    data: list[list[Paragraph]] = []
    for row_index, row in enumerate(rows):
        cells: list[Paragraph] = []
        for column_index, value in enumerate(row):
            if row_index < repeat_rows:
                style = styles["table_header"]
            elif alignment_map.get(column_index) == "RIGHT":
                style = styles["table_right"]
            elif alignment_map.get(column_index) == "CENTER":
                style = styles["table_center"]
            elif column_index == 0:
                style = styles["table_first"]
            else:
                style = styles["table"]
            cells.append(table_cell(value, style))
        data.append(cells)
    result = LongTable(data, colWidths=widths, repeatRows=repeat_rows, hAlign="LEFT")
    commands: list[tuple] = [
        ("BACKGROUND", (0, 0), (-1, repeat_rows - 1), colors.black),
        ("TEXTCOLOR", (0, 0), (-1, repeat_rows - 1), colors.white),
        ("BOX", (0, 0), (-1, -1), 0.65, colors.black),
        ("INNERGRID", (0, 0), (-1, -1), 0.28, colors.HexColor("#6A6A6A")),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 3.2),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3.2),
        ("TOPPADDING", (0, 0), (-1, -1), 2.2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2.2),
    ]
    for row_index in range(repeat_rows + 1, len(rows), 2):
        commands.append(("BACKGROUND", (0, row_index), (-1, row_index), colors.HexColor("#F2F2F2")))
    result.setStyle(TableStyle(commands))
    return result


def divider() -> Table:
    line = Table([[""]], colWidths=[CONTENT_WIDTH], rowHeights=[0.8])
    line.setStyle(TableStyle([("LINEBELOW", (0, 0), (-1, -1), 1.2, colors.black)]))
    return line


def draw_page(canvas, doc) -> None:
    canvas.saveState()
    canvas.setStrokeColor(colors.black)
    canvas.setLineWidth(0.45)
    canvas.line(LEFT_MARGIN, 10 * mm, PAGE_WIDTH - RIGHT_MARGIN, 10 * mm)
    canvas.setFont(FONT_REGULAR, 7.5)
    canvas.drawString(LEFT_MARGIN, 6 * mm, "Loopy 本地模型单双设备协同推理测试汇总")
    canvas.drawRightString(PAGE_WIDTH - RIGHT_MARGIN, 6 * mm, f"第 {doc.page} 页")
    canvas.restoreState()


def status_cn(value: str) -> str:
    mapping = {
        "PASS": "通过",
        "FAIL_AFTER_FIRST_FUNCTION_CALL": "失败: 第二次推理无回调",
        "FAIL_NO_TOOL_CALL": "失败: 未调用工具",
        "FAIL_SECOND_INFERENCE_TIMEOUT": "失败: 第二次推理超时",
        "FAIL_NO_NOTE_ACTIONS": "失败: 未执行 note",
        "NOT_RUN": "未运行",
    }
    return mapping.get(value, value)


def build_story(styles: dict[str, ParagraphStyle]) -> list:
    bfcl_rows = load_csv(ARTIFACT_ROOT / "comparison.csv")
    skill_summary = load_json(ARTIFACT_ROOT / "skills" / "results.json")
    complex_rows = load_csv(ARTIFACT_ROOT / "complex_prompts" / "comparison.csv")
    complex_single = {
        row["id"]: row
        for row in load_csv(ARTIFACT_ROOT / "complex_prompts" / "single_final_v2" / "results.csv")
    }

    story: list = []
    story.extend([
        Spacer(1, 4 * mm),
        p("Loopy 本地模型单双设备协同推理测试汇总", styles["title"]),
        divider(),
        Spacer(1, 2 * mm),
        p("Qwen2.5-7B-Instruct Q4 / Gewu / KNPU / 两台 Mate 70", styles["subtitle"]),
        p("测试日期: 2026-08-11　整理日期: 2026-08-12　呈现形式: 黑白文字与表格", styles["body"]),
        Spacer(1, 2 * mm),
        p("结论摘要", styles["h1"]),
        bullet("共整理 3 组测试集、10 个场景。所有正式性能数据均来自每场景 1 次运行，没有冷热启动拆分、顺序随机化或重复采样。", styles),
        bullet("单次、无工具的双设备推理可以稳定完成。4 个可直接比较的单次场景中，双设备 E2E 比单设备快 5.44% 至 10.58%。", styles),
        bullet("双设备主要降低 Prefill。复杂 Prompt 的 Prefill 降低 22.44% 至 27.41%，Decode 基本不变或略慢。", styles),
        bullet("同一 Agent 回合内的多步路径仍不稳定。time 工具和 read Skill 都在第一次双端推理完成后，第二次推理没有首回调。", styles),
        bullet("复杂 Prompt 的运行时完成率为 3/3，但单机和双机的答案准确率均为 0/3。性能完成和模型推理质量必须分开解读。", styles),
        Spacer(1, 1.5 * mm),
        p("报告口径", styles["h2"]),
        p("本报告使用最终选定的可比运行作为主表。早期固定超时、锁屏、UI 输入失败等调试性运行只用于定位问题，不混入加速比。双设备主机和协作者计时并行发生，不能相加。", styles["note"]),
    ])

    story.extend([
        p("1. 测试环境与指标定义", styles["h1"]),
        make_table([
            ["项目", "配置或口径"],
            ["主机", "Mate 70, 设备 53V0224C19002918, 192.168.43.1"],
            ["协作者", "Mate 70, 设备 53V0224C19002841, 192.168.43.4"],
            ["模型", "Qwen2.5-7B-Instruct Q4"],
            ["推理运行时", "Gewu + KNPU, max_ctx=2048"],
            ["协同切分", "主机层 0-12; 协作者层 13-27; TCP 控制链路端口 19091"],
            ["控制变量", "相同 Loopy、模型、System/ReAct Prompt、工具和 Skill 描述; 单机仅关闭 collaboration"],
            ["重复策略", "每场景 1 次; 无冷热启动拆分; 无顺序随机化"],
        ], [36 * mm, CONTENT_WIDTH - 36 * mm], styles, alignments={0: "LEFT"}),
        Spacer(1, 2 * mm),
        p("指标定义", styles["h2"]),
        make_table([
            ["指标", "含义", "解读限制"],
            ["E2E", "从点击发送到 Loopy UI 恢复可发送的总时长", "包含 Prefill、Decode、Agent/tool、建会与界面开销"],
            ["Prefill", "处理完整输入上下文的时长", "包含 System/ReAct Prompt、工具、Skill 描述和用户输入; 当前无法单独拆出 System Prompt"],
            ["Decode", "逐 token 自回归生成时长", "层切分仍需逐 token 跨设备同步，因此不一定加速"],
            ["其他开销", "E2E - Prefill - Decode", "含建会、ready、传输、Agent/tool、UI 等，不代表单一组件"],
            ["输入/输出 token", "完成推理调用的 token 合计", "多步任务是多次调用合计; 失败任务可能只记录第一轮"],
        ], [25 * mm, 74 * mm, CONTENT_WIDTH - 99 * mm], styles),
        Spacer(1, 2 * mm),
        p("2. 测试集与场景清单", styles["h1"]),
        make_table([
            ["测试集", "场景数", "场景内容", "主要目的"],
            ["BFCL 衍生工具调用", "4", "无工具回答; time 单工具; note 单工具; 两个 note 并行", "验证 ReAct 工具选择、执行和多步返回; 非官方 BFCL 榜单分数"],
            ["Progressive Skill", "3", "read 后返回口令; read + time; read + 两个 note", "验证 Skill 匹配、读取、后续工具调用与多次模型推理"],
            ["复杂 Prompt", "3", "短算术; 中等关键路径; 长记录筛选", "隔离工具/Skill 多步复用，比较不同输入长度和推理复杂度"],
        ], [37 * mm, 18 * mm, 86 * mm, CONTENT_WIDTH - 141 * mm], styles),
    ])

    story.extend([
        p("3. BFCL 衍生工具调用测试", styles["h1"]),
        p("测试内容: 使用 BFCL 类别形态适配 Loopy 内置的 time 和 note 工具。通过条件同时检查工具调用、固定文本和最终返回。", styles["body"]),
        make_table([
            ["场景", "内容与执行路径", "单机结果", "双机结果"],
            ["无工具回答", "计算底 10、高 5 的三角形面积; 禁止工具", "通过", "通过; 两端均参与"],
            ["time 单工具", "推理 -> time -> 第二次推理 -> Final", "通过", "第一次双端推理和工具选择完成; 第二次推理无回调"],
            ["note 单工具", "要求 note 写入固定文本", "失败: 模型复述文本，未调用 note", "未运行"],
            ["两个 note 并行", "一次并行计划调用两个 note，再汇总结果", "通过", "未运行"],
        ], [34 * mm, 84 * mm, 58 * mm, CONTENT_WIDTH - 176 * mm], styles),
        Spacer(1, 2 * mm),
        p("详细时延和 token 数据", styles["h2"]),
    ])
    bfcl_table = [["场景/模式", "状态", "E2E(s)", "调用数", "输入/输出 token", "Prefill(s)", "Decode(s)", "说明"]]
    bfcl_single_tokens = {
        "bfcl_irrelevance_0_adapted": (1, "893/35"),
        "bfcl_simple_time_adapted": (2, "1820/41"),
        "bfcl_simple_note_adapted": (1, "893/55"),
        "bfcl_parallel_note_adapted": (2, "1879/65"),
    }
    labels = {
        "bfcl_irrelevance_0_adapted": "无工具回答",
        "bfcl_simple_time_adapted": "time 单工具",
        "bfcl_simple_note_adapted": "note 单工具",
        "bfcl_parallel_note_adapted": "两个 note 并行",
    }
    for row in bfcl_rows:
        case_id = row["case"]
        calls, tokens = bfcl_single_tokens[case_id]
        bfcl_table.append([
            f"{labels[case_id]} / 单机", status_cn(row["single_status"]), seconds(row["single_e2e_ms"]), calls,
            tokens, seconds(row["single_prefill_ms"]), seconds(row["single_decode_ms"]), "完整任务统计",
        ])
        if row["dual_status"] == "PASS":
            bfcl_table.append([
                f"{labels[case_id]} / 双机", "通过", seconds(row["dual_e2e_ms"]), 1,
                "主893/35; 协893/34", seconds(row["dual_master_prefill_ms"]),
                seconds(row["dual_master_decode_ms"]), "协作者 P/D=19.538/30.330s; E2E 快10.58%",
            ])
        elif row["dual_status"] == "FAIL_AFTER_FIRST_FUNCTION_CALL":
            bfcl_table.append([
                f"{labels[case_id]} / 双机", status_cn(row["dual_status"]), "-", "完成1次",
                "协888/9", "协18.974", "协8.063", "仅第一轮协作者统计; 不可与完整任务比较",
            ])
        else:
            bfcl_table.append([
                f"{labels[case_id]} / 双机", "未运行", "-", "-", "-", "-", "-", "前置双机多步任务失败后停止",
            ])
    story.extend([
        make_table(bfcl_table, [38 * mm, 31 * mm, 18 * mm, 18 * mm, 31 * mm, 23 * mm, 23 * mm, CONTENT_WIDTH - 182 * mm], styles,
                   alignments={2: "RIGHT", 3: "CENTER", 5: "RIGHT", 6: "RIGHT"}),
        p("注: 双机 time 的 UI/冻结过程不构成有效完整 E2E; 表中仅保留第一次协作者推理的原始统计。", styles["note"]),
    ])

    story.extend([
        p("4. Progressive Skill 测试", styles["h1"]),
        p("测试内容: 模型先从 available_skills 选择 Skill，调用 read 读取完整 SKILL.md，再返回答案或继续调用 time/note。", styles["body"]),
        make_table([
            ["场景", "预期路径", "功能判定"],
            ["规则口令", "推理 -> read benchmark_codeword -> 第二次推理 -> Final", "单机通过; 双机第二次推理超时"],
            ["设备时间报告", "推理 -> read -> 推理 -> time -> 推理 -> Final", "单机通过; 双机因前置失败未运行"],
            ["并行 note", "推理 -> read -> 推理 -> note + note -> Final", "单机选择 Skill，但未执行两个 note; 双机未运行"],
        ], [38 * mm, 102 * mm, CONTENT_WIDTH - 140 * mm], styles),
        Spacer(1, 2 * mm),
        p("详细时延和 token 数据", styles["h2"]),
    ])
    skill_single = {item["id"]: item for item in skill_summary["single"]["results"]}
    skill_dual = {item["id"]: item for item in skill_summary["dual"]["results"]}
    skill_meta = {
        "skill_rules_codeword": ("规则口令", "2739/47"),
        "skill_single_time": ("设备时间报告", "4196/83"),
        "skill_parallel_notes": ("并行 note", "2787/85"),
    }
    skill_table = [["场景/模式", "状态", "E2E(s)", "完成调用", "输入/输出 token", "Prefill(s)", "Decode(s)", "说明"]]
    for case_id in ["skill_rules_codeword", "skill_single_time", "skill_parallel_notes"]:
        item = skill_single[case_id]
        label, tokens = skill_meta[case_id]
        skill_table.append([
            f"{label} / 单机", status_cn(item["status"]), seconds(item["e2eMs"]), item["inferenceCalls"], tokens,
            seconds(item["prefillMsTotal"]), seconds(item["decodeMsTotal"]), "完成调用的合计统计",
        ])
        dual_item = skill_dual.get(case_id)
        if dual_item is not None:
            skill_table.append([
                f"{label} / 双机", status_cn(dual_item["status"]), seconds(dual_item["e2eMs"]),
                dual_item["completedInferenceCalls"],
                f"主{dual_item['master']['inputTokens']}/{dual_item['master']['outputTokens']}; 协{dual_item['collaborator']['inputTokens']}/{dual_item['collaborator']['outputTokens']}",
                seconds(dual_item["master"]["prefillMs"]), seconds(dual_item["master"]["decodeMs"]),
                f"协作者 P/D={seconds(dual_item['collaborator']['prefillMs'])}/{seconds(dual_item['collaborator']['decodeMs'])}s; 仅第一轮完成",
            ])
        else:
            skill_table.append([f"{label} / 双机", "未运行", "-", "-", "-", "-", "-", "前置 read -> Final 双机失败后停止"])
    story.extend([
        make_table(skill_table, [37 * mm, 32 * mm, 18 * mm, 19 * mm, 37 * mm, 22 * mm, 22 * mm, CONTENT_WIDTH - 187 * mm], styles,
                   alignments={2: "RIGHT", 3: "CENTER", 5: "RIGHT", 6: "RIGHT"}),
        p("结论: 单机可以完成两次和三次模型推理的 Skill 路径。双机规则口令的第一次推理两端输入 token 同为 1319，并成功调用 read，但第二次推理没有首回调，因此 108.691 秒不是成功任务时延。", styles["note"]),
    ])

    story.extend([
        p("5. 不同复杂度 Prompt 测试", styles["h1"]),
        p("测试内容: 不调用工具和 Skill，固定短输出格式，减少 Decode 长度差异。该组主要观察输入长度、Prefill 和双机层切分协同。", styles["body"]),
        make_table([
            ["场景", "输入内容", "期望输出"],
            ["短算术", "计算 (17 x 19) - (23 x 7) + 5", "COMPLEX_SHORT=167"],
            ["中等关键路径", "A/B/C/D 依赖图，求最短完工时间和关键路径", "CRITICAL_PATH=A-C-D;TOTAL=10"],
            ["长记录筛选", "按区域、active、分数过滤 12 条记录，再排序求和", "SELECTED=R09,R01,R07,R04,R11;SUM=437"],
        ], [35 * mm, 107 * mm, CONTENT_WIDTH - 142 * mm], styles),
        Spacer(1, 2 * mm),
        p("单双机主表", styles["h2"]),
    ])
    complex_labels = {
        "complex_short_arithmetic": "短算术",
        "complex_medium_critical_path": "中等关键路径",
        "complex_long_record_filter": "长记录筛选",
    }
    complex_output_tokens = {
        "complex_short_arithmetic": (17, 17, 16),
        "complex_medium_critical_path": (13, 13, 12),
        "complex_long_record_filter": (39, 39, 38),
    }
    complex_table = [["场景", "输入/输出 token (单/主/协)", "单机 E2E", "单机 P/D", "双机 E2E", "双机主 P/D", "双机协 P/D", "E2E变化", "答案"]]
    for row in complex_rows:
        single_out, master_out, collaborator_out = complex_output_tokens[row["case"]]
        token_count = row["input_tokens"]
        complex_table.append([
            complex_labels[row["case"]],
            f"{token_count}/{single_out}; {token_count}/{master_out}; {token_count}/{collaborator_out}",
            f"{seconds(row['single_e2e_ms'])}s",
            f"{seconds(row['single_prefill_ms'])}/{seconds(row['single_decode_ms'])}s",
            f"{seconds(row['dual_e2e_ms'])}s",
            f"{seconds(row['dual_master_prefill_ms'])}/{seconds(row['dual_master_decode_ms'])}s",
            f"{seconds(row['dual_collaborator_prefill_ms'])}/{seconds(row['dual_collaborator_decode_ms'])}s",
            f"快 {row['e2e_improvement_pct']}%", "单/双均错误",
        ])
    story.extend([
        make_table(complex_table, [28 * mm, 35 * mm, 22 * mm, 32 * mm, 22 * mm, 32 * mm, 32 * mm, 24 * mm, CONTENT_WIDTH - 227 * mm], styles,
                   alignments={1: "RIGHT", 2: "RIGHT", 4: "RIGHT", 7: "RIGHT"}),
        Spacer(1, 2 * mm),
        p("E2E 阶段拆分", styles["h2"]),
    ])
    breakdown = [["场景", "单机 Prefill占比", "单机 Decode占比", "单机其他", "双机 Prefill占比", "双机 Decode占比", "双机其他", "Prefill节省"]]
    for row in complex_rows:
        se = float(row["single_e2e_ms"])
        sp = float(row["single_prefill_ms"])
        sd = float(row["single_decode_ms"])
        de = float(row["dual_e2e_ms"])
        dp = float(row["dual_master_prefill_ms"])
        dd = float(row["dual_master_decode_ms"])
        breakdown.append([
            complex_labels[row["case"]], f"{sp / se * 100:.1f}%", f"{sd / se * 100:.1f}%", f"{(se-sp-sd)/1000:.3f}s",
            f"{dp / de * 100:.1f}%", f"{dd / de * 100:.1f}%", f"{(de-dp-dd)/1000:.3f}s",
            f"{(sp-dp)/sp*100:.2f}%",
        ])
    story.extend([
        make_table(breakdown, [30 * mm, 27 * mm, 27 * mm, 24 * mm, 27 * mm, 27 * mm, 24 * mm, CONTENT_WIDTH - 186 * mm], styles,
                   alignments={1: "RIGHT", 2: "RIGHT", 3: "RIGHT", 4: "RIGHT", 5: "RIGHT", 6: "RIGHT", 7: "RIGHT"}),
        p("复杂 Prompt 三个场景均完成 session_ready -> inference -> session_ended。两端输入 token 分别匹配为 1351、1401、1612。双机主要减少 Prefill，Decode 基本持平或略慢。", styles["note"]),
    ])

    story.extend([
        PageBreak(),
        p("6. 综合结论、超时边界与数据限制", styles["h1"]),
        p("单双机表现总结", styles["h2"]),
        make_table([
            ["观察项", "结果", "可得结论"],
            ["单次无工具推理", "BFCL 无工具快 10.58%; 复杂 Prompt 快 5.44%-7.90%", "双机链路和层切分真实工作，但单次样本不足以形成稳定性能结论"],
            ["Prefill", "复杂 Prompt 双机主侧降低 22.44%-27.41%", "长输入更可能受益"],
            ["Decode", "基本持平，短/中场景略慢", "逐 token 层间依赖和跨设备同步没有被消除"],
            ["多步 Agent", "time 和 read Skill 均在第一次双端推理后，第二次推理无首回调", "故障集中在同一 Agent 回合内的分布式 Session/KV 多请求生命周期"],
            ["模型质量", "复杂 Prompt 单/双均 0/3", "协同完成不等于答案正确; 当前 Q4 模型指令和推理质量仍有限"],
        ], [34 * mm, 82 * mm, CONTENT_WIDTH - 116 * mm], styles),
        Spacer(1, 2 * mm),
        p("已定位的超时或假卡死来源", styles["h2"]),
        make_table([
            ["现象", "原因", "当前处理"],
            ["Prefill 首响应超时", "真实 Prefill 时长随上下文和设备状态波动", "已取消应用侧 Prefill 超时上限"],
            ["120/180/300 秒总超时", "仍有 token 回调的 Decode 被固定总时限中止", "30 秒流停滞 watchdog + 600 秒绝对上限"],
            ["长任务看似卡死", "手机锁屏后 UI 自动化看到锁屏而不是 Loopy", "推理期间保持亮屏"],
            ["没有真正提交 Prompt", "uitest inputText 偶发静默失败", "发送前校验 TextInput 并重试"],
            ["双机多步第二次推理超时", "第一次请求后协同 Session/KV 状态无法可靠复用", "尚未彻底修复; 应在模型调用之间做配对 Session 生命周期验证"],
            ["destroy co session failed", "协作者已 suspended 后 Gewu 仍打印销毁告警", "后续新会话可成功; 作为运行库残留告警监控，不等同推理超时"],
        ], [45 * mm, 102 * mm, CONTENT_WIDTH - 147 * mm], styles),
        Spacer(1, 2 * mm),
        p("数据限制", styles["h2"]),
        bullet("每个场景只有 1 次正式测量，无法给出方差、P50/P95 或统计显著性。", styles),
        bullet("System Prompt、ReAct、工具和 Skill 描述包含在 Prefill 中; 当前 Gewu 日志不能单独提供 System Prompt 时延。", styles),
        bullet("双机失败任务只保留已完成的第一次推理数据，不应把该数据与单机完整 E2E 直接比较。", styles),
        bullet("准确率失败和运行时超时是不同问题，本报告分别呈现。", styles),
        Spacer(1, 1.5 * mm),
        p("原始数据位置", styles["h2"]),
        p("benchmark_artifacts/bfcl_20260811/README.md<br/>benchmark_artifacts/bfcl_20260811/comparison.csv<br/>benchmark_artifacts/bfcl_20260811/skills/results.json<br/>benchmark_artifacts/bfcl_20260811/skills/comparison.csv<br/>benchmark_artifacts/bfcl_20260811/complex_prompts/README.md<br/>benchmark_artifacts/bfcl_20260811/complex_prompts/comparison.csv", styles["small"]),
    ])
    return story


def main() -> None:
    register_fonts()
    styles = build_styles()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    frame = Frame(
        LEFT_MARGIN,
        BOTTOM_MARGIN,
        CONTENT_WIDTH,
        PAGE_HEIGHT - TOP_MARGIN - BOTTOM_MARGIN,
        leftPadding=0,
        rightPadding=0,
        topPadding=0,
        bottomPadding=0,
    )
    template = PageTemplate(id="report", frames=[frame], onPage=draw_page)
    document = BaseDocTemplate(
        str(OUTPUT_PATH),
        pagesize=PAGE_SIZE,
        leftMargin=LEFT_MARGIN,
        rightMargin=RIGHT_MARGIN,
        topMargin=TOP_MARGIN,
        bottomMargin=BOTTOM_MARGIN,
        title="Loopy 本地模型单双设备协同推理测试汇总",
        author="Codex",
        subject="Qwen2.5 Gewu KNPU single-device and dual-device benchmark summary",
    )
    document.addPageTemplates([template])
    document.build(build_story(styles))
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
