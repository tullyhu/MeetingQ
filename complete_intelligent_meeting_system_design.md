# 智能会议纪要系统 - 完整设计文档（多模态融合版）

## 一、系统概述

### 1.1 产品定位

**智能会议纪要系统** = ASR 转写 + 多模态画面分析 + 智能模板推荐 + AI 纪要生成

- **目标用户**：企业团队、项目组、管理层
- **核心价值**：自动生成高端、专业、可执行的会议纪要，节省 90% 手工整理时间
- **差异化优势**：多模态融合分析（ASR+PPT+ 图表 + 场景），智能模板匹配，高端视觉设计

### 1.2 核心功能模块

```
┌─────────────────────────────────────────────────────────────┐
│                    智能会议纪要系统                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  【输入层】                                                 │
│   • 会议录音 → ASR 转写                                     │
│   • 会议视频 → 画面分析（PPT/图表/白板 OCR）                │
│   • 会议元数据 → 标题、时间、时长                           │
│                                                             │
│  【智能分析层】                                             │
│   • ASR 特征提取 → 会议类型、正式度、决策密度               │
│   • OCR 特征提取 → PPT 关键信息、图表数据、白板内容         │
│   • 多模态融合 → 时间对齐、一致性检查、置信度评估           │
│                                                             │
│  【模板推荐层】                                             │
│   • 特征匹配 → 基于多模态特征选择最优模板                   │
│   • 用户确认 → 展示推荐原因，支持手动覆盖                   │
│   • 12 套模板库 → 高端商务/技术评审/客户会议/站会...         │
│                                                             │
│  【AI 生成层】                                               │
│   • Prompt 组装 → 动态填充角色、任务、输出要求              │
│   • 纪要生成 → 调用 LLM 生成结构化纪要                       │
│   • 质量评估 → 5 维度评分、置信度、需复核标记                │
│                                                             │
│  【输出层】                                                 │
│   • 会议纪要 → 高端商务风格 Markdown/HTML/PDF               │
│   • 会议记录 → 完整转写 + 关键片段索引                      │
│   • 主题聚合 → 跨会议主题追踪、时间线视图                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 信息源全景图

| 信息源 | 可用性 | 可获取内容 | 使用方式 |
|--------|--------|------------|----------|
| **ASR 转写** | ✅ 高 | 完整对话、时间戳、说话人分离 | 核心信息源，必用 |
| **PPT/文档 OCR** | ✅ 中 | PPT 标题、关键日期、数字、决策、行动项 | 强烈推荐，提取关键信息 |
| **图表识别** | ✅ 中 | 图表类型、数据点、趋势 | 推荐，数据密集型会议使用 |
| **白板识别** | ⚠️ 中 | 创意列表、投票结果、行动项 | 选择性使用，创意会议使用 |
| **场景分类** | ✅ 中 | PPT 共享、数据报表、白板讨论 | 推荐，识别会议阶段 |
| **参会人列表** | ❌ 低 | 通常不可用 | 不依赖，仅基于内容特征 |

---

## 二、系统架构

### 2.1 完整架构图

```
┌──────────────────────────────────────────────────────────────┐
│                      用户界面层                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐            │
│  │ 上传会议   │  │ 模板选择   │  │ 纪要预览   │            │
│  │ 录音/视频  │  │ 确认界面   │  │ & 编辑     │            │
│  └────────────┘  └────────────┘  └────────────┘            │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│                      API 网关层                               │
│  • POST /upload-meeting                                      │
│  • GET /recommend-template                                   │
│  • POST /generate-minutes                                    │
│  • POST /assess-quality                                      │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│                    业务逻辑层                                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 特征提取引擎                                         │   │
│  │ • ASR 特征提取                                        │   │
│  │ • OCR 特征提取                                        │   │
│  │ • 图表识别                                            │   │
│  │ • 场景分类                                            │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 多模态融合引擎                                       │   │
│  │ • 时间对齐（ASR 时间戳 + 视频帧）                     │   │
│  │ • 内容关联（说到即看到）                             │   │
│  │ • 一致性检查（ASR vs PPT）                           │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 模板推荐引擎                                         │   │
│  │ • 多模态特征匹配                                     │   │
│  │ • 模板评分排序                                       │   │
│  │ • 推荐原因生成                                       │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ AI 生成引擎                                           │   │
│  │ • Prompt 动态组装                                     │   │
│  │ • LLM 调用（GPT-4/Claude/本地模型）                   │   │
│  │ • 流式输出                                            │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 质量评估引擎                                         │   │
│  │ • 5 维度评分                                         │   │
│  │ • 置信度评估                                         │   │
│  │ • 需复核标记                                         │   │
│  └──────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│                      数据持久层                              │
│  • PostgreSQL：会议纪要、模板、特征数据                     │
│  • Elasticsearch：全文搜索、关键词索引                       │
│  • S3/OSS：录音、视频、截图存储                             │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 核心流程

```
【步骤 1】上传会议
  用户上传录音/视频 → 存储到 S3 → 触发异步处理任务

【步骤 2】并行处理
  ├─ ASR 转写引擎 → 完整转写文本 + 时间戳 + 说话人分离
  ├─ 视频处理引擎 → 关键帧提取 + 场景分类
  ├─ OCR 引擎 → PPT/文档/白板文字识别
  └─ 图表识别引擎 → 图表类型识别 + 数据提取

【步骤 3】特征提取
  ├─ ASR 特征 → 会议类型预测、正式度、决策密度、行动项密度
  ├─ OCR 特征 → PPT 关键信息（日期、数字、决策、行动项）
  ├─ 图表特征 → 数据点、趋势、讨论时刻
  └─ 场景特征 → 场景时间线、主要场景类型

【步骤 4】多模态融合
  ├─ 时间对齐 → ASR 时间戳与视频帧同步
  ├─ 内容关联 → 识别"说到即看到"的关键时刻
  └─ 一致性检查 → ASR 与 PPT 信息对比

【步骤 5】模板推荐
  ├─ 基于多模态特征匹配 12 套模板
  ├─ 计算匹配分数和推荐原因
  └─ 返回 Top 3 推荐给用户

【步骤 6】用户确认
  ├─ 展示推荐模板及匹配原因
  ├─ 用户可选择推荐或手动切换
  └─ 确认后进入生成流程

【步骤 7】AI 生成
  ├─ 动态组装 Prompt（角色 + 任务 + 输出要求）
  ├─ 调用 LLM 生成会议纪要
  ├─ 流式输出，实时预览
  └─ 生成会议记录（完整转写）

【步骤 8】质量评估
  ├─ 5 维度评分（决策完整性、行动项格式、准确性、模板符合度、语言质量）
  ├─ 置信度评估（High/Medium/Low）
  ├─ 标记需复核内容
  └─ 用户确认或编辑

【步骤 9】格式渲染
  ├─ 按设计语言规范渲染 Markdown/HTML
  ├─ 生成 PDF/Word 导出文件
  └─ 支持分享到协作平台

【步骤 10】反馈优化
  ├─ 用户满意度评分（1-5 星）
  ├─ 收集改进建议
  └─ 用于优化模板推荐算法
```

---

## 三、多模态特征提取

### 3.1 ASR 特征提取

#### 可提取特征

| 特征 | 提取方法 | 示例 |
|------|----------|------|
| **会议类型预测** | 关键词密度 + 语言模式 | 技术术语多→技术评审 |
| **正式程度** | 正式/非正式用语比例 | "请"vs"咱们" |
| **决策密度** | 决策关键词/总字数 | "决定"、"确定"出现频率 |
| **行动项密度** | 行动关键词/总字数 | "需要"、"负责"出现频率 |
| **技术术语密度** | 技术词/总字数 | bug、API、接口 |
| **商务术语密度** | 商务词/总字数 | 预算、客户、合同 |
| **语言类型** | 中英文比例 | 英文>30%→双语版 |
| **讨论激烈度** | 疑问句 + 感叹句频率 | 头脑风暴→激烈 |

#### 特征提取算法

```python
def extract_asr_features(transcript, metadata):
    """
    从 ASR 转写文本提取特征
    """
    text = transcript["full_text"]
    word_count = len(text)
    
    features = {
        # 1. 会议类型预测
        "meeting_type_prediction": predict_meeting_type(text, metadata),
        
        # 2. 正式程度评估
        "formality_level": assess_formality(text),
        
        # 3. 决策密度
        "decision_density": calculate_keyword_density(text, DECISION_KEYWORDS),
        
        # 4. 行动项密度
        "action_density": calculate_keyword_density(text, ACTION_KEYWORDS),
        
        # 5. 技术术语密度
        "technical_density": calculate_keyword_density(text, TECHNICAL_TERMS),
        
        # 6. 商务术语密度
        "business_density": calculate_keyword_density(text, BUSINESS_TERMS),
        
        # 7. 语言类型
        "language_type": detect_language_type(text),
        
        # 8. 讨论激烈程度
        "discussion_intensity": assess_discussion_intensity(text)
    }
    
    return features

def predict_meeting_type(text, metadata):
    """
    基于关键词和语言模式预测会议类型
    """
    scores = {}
    
    # 技术评审特征
    tech_score = calculate_keyword_density(text, TECHNICAL_TERMS)
    if tech_score > 0.05:
        scores["technical_review"] = tech_score * 10
    
    # 高管会议特征
    business_score = calculate_keyword_density(text, BUSINESS_TERMS)
    decision_score = calculate_keyword_density(text, DECISION_KEYWORDS)
    if business_score > 0.05 and decision_score > 0.02:
        scores["executive_meeting"] = (business_score + decision_score) * 8
    
    # 客户会议特征
    client_keywords = ["客户", "贵司", "方案", "需求", "报价", "合同"]
    client_score = calculate_keyword_density(text, client_keywords)
    if client_score > 0.03:
        scores["client_meeting"] = client_score * 9
    
    # 返回得分最高的类型
    if scores:
        best_match = max(scores.items(), key=lambda x: x[1])
        return {
            "predicted_type": best_match[0],
            "confidence": min(best_match[1] / 10, 1.0),
            "scores": scores
        }
    else:
        return {"predicted_type": "general_meeting", "confidence": 0.5}
```

### 3.2 OCR 特征提取（PPT/文档）

#### Prompt 模板

```markdown
# Role
你是一位专业的 PPT 内容分析助手，擅长从会议共享的 PPT 页面中提取关键业务信息。

# Task
请分析以下 PPT 页面的 OCR 文字，提取关键信息用于会议纪要生成。

# Input
- PPT 页码：[第 X 页 / 共 Y 页]
- 时间戳：[HH:MM:SS]
- OCR 文字内容：
```
[粘贴 OCR 识别的完整文字]
```

# Output Requirements
请以 JSON 格式输出：
{
  "slide_number": "数字",
  "timestamp": "字符串",
  "title": "字符串，PPT 页面标题",
  "key_dates": [
    {
      "date": "字符串，日期（YYYY-MM-DD）",
      "context": "字符串，日期的上下文",
      "confidence": "字符串，high|medium|low"
    }
  ],
  "key_numbers": [
    {
      "value": "字符串，数字 + 单位",
      "context": "字符串，数字的含义",
      "confidence": "字符串"
    }
  ],
  "decisions": [
    {
      "text": "字符串，决策内容原文",
      "type": "字符串，决策类型",
      "confidence": "字符串"
    }
  ],
  "action_items": [
    {
      "text": "字符串，行动项原文",
      "deadline": "字符串，截止时间",
      "owner": "字符串，负责人",
      "confidence": "字符串"
    }
  ],
  "topics_covered": ["字符串数组，主题关键词"],
  "summary": "字符串，1 句话概括"
}

# Extraction Guidelines
- 优先级：日期、数字、决策、行动项
- 日期标准化：统一为 YYYY-MM-DD 格式
- 置信度：high（清晰明确）| medium（部分模糊）| low（不确定）
```

#### 输出示例

```json
{
  "slide_number": 15,
  "timestamp": "14:12:35",
  "title": "第三章 上线计划",
  "key_dates": [
    {
      "date": "2026-09-10",
      "context": "正式上线",
      "confidence": "high"
    }
  ],
  "key_numbers": [
    {
      "value": "250 万",
      "context": "预算",
      "confidence": "high"
    }
  ],
  "action_items": [
    {
      "text": "9/5 完成 UAT 测试",
      "deadline": "2026-09-05",
      "confidence": "high"
    }
  ],
  "topics_covered": ["上线计划", "里程碑", "预算"],
  "summary": "本章介绍产品上线的关键里程碑，包括 9/5 测试、9/8 验收、9/10 上线，预算 250 万"
}
```

### 3.3 图表特征提取

#### Prompt 模板

```markdown
# Role
你是一位专业的图表分析助手，擅长从会议共享的柱状图、折线图中提取数据。

# Task
请分析以下图表的 OCR 文字和视觉描述，提取数据点和趋势信息。

# Input
- 图表类型：[柱状图/折线图/饼图/表格]
- 时间戳：[HH:MM:SS]
- 图表标题：[如有]
- OCR 文字（坐标轴标签、数据标签等）：
```
[粘贴 OCR 识别的文字]
```
- 视觉描述（可选）：
```
[描述：如"柱状图显示 3 个产品线，产品线 A 最高，约 1200 万"]
```

# Output Requirements
请以 JSON 格式输出：
{
  "chart_type": "字符串，bar_chart|line_chart|pie_chart|table",
  "timestamp": "字符串",
  "title": "字符串，图表标题",
  "data_points": [
    {
      "category": "字符串，类别名称",
      "value": "数字或字符串，数值",
      "unit": "字符串，单位",
      "visual_description": "字符串，视觉描述",
      "confidence": "字符串"
    }
  ],
  "trends_identified": [
    {
      "trend_type": "字符串，increasing|decreasing|stable",
      "description": "字符串，趋势描述",
      "confidence": "字符串"
    }
  ],
  "key_insights": [
    {
      "insight": "字符串，关键洞察",
      "evidence": "字符串，支持证据",
      "confidence": "字符串"
    }
  ],
  "summary": "字符串，1-2 句话概括"
}
```

#### 输出示例

```json
{
  "chart_type": "bar_chart",
  "timestamp": "14:25:00",
  "title": "Q3 各产品线收入对比",
  "data_points": [
    {
      "category": "产品线 A",
      "value": 1200,
      "unit": "万元",
      "visual_description": "最高",
      "confidence": "high"
    },
    {
      "category": "产品线 B",
      "value": 850,
      "unit": "万元",
      "visual_description": "中等",
      "confidence": "high"
    }
  ],
  "trends_identified": [
    {
      "trend_type": "descending",
      "description": "产品线 A > B > C，收入逐级递减",
      "confidence": "high"
    }
  ],
  "key_insights": [
    {
      "insight": "产品线 A 收入最高（1200 万），是产品线 C 的近 2 倍",
      "evidence": "数据点对比：1200 vs 620",
      "confidence": "high"
    }
  ],
  "summary": "Q3 收入对比显示产品线 A（1200 万）表现最好，产品线 B（850 万）中等，产品线 C（620 万）最弱"
}
```

### 3.4 多模态融合

#### 时间对齐算法

```python
def align_audio_visual_features(asr_transcript, video_features):
    """
    将 ASR 转写与画面信息时间对齐
    识别"说到即看到"的关键时刻
    """
    aligned_features = {
        "decision_moments": [],
        "data_discussion_moments": [],
        "action_item_assignment_moments": []
    }
    
    # 1. 识别决策时刻（ASR 中的决策关键词 + PPT 中的决策文字）
    for decision_in_asr in extract_decisions_from_asr(asr_transcript):
        decision_timestamp = decision_in_asr["timestamp"]
        
        # 查找前后 5 秒内的 PPT 内容
        ppt_content = find_ppt_content_at_time(
            video_features["ppt_features"],
            decision_timestamp,
            tolerance_seconds=5
        )
        
        if ppt_content and contains_decision_text(ppt_content):
            # ASR 和 PPT 都提到决策，高置信度
            aligned_features["decision_moments"].append({
                "timestamp": decision_timestamp,
                "asr_text": decision_in_asr["text"],
                "ppt_text": ppt_content,
                "confidence": "high"
            })
        else:
            # 仅 ASR 提到决策
            aligned_features["decision_moments"].append({
                "timestamp": decision_timestamp,
                "asr_text": decision_in_asr["text"],
                "ppt_text": None,
                "confidence": "medium"
            })
    
    # 2. 识别数据讨论时刻（ASR 提到数字 + 画面显示图表）
    for number_mention in extract_numbers_from_asr(asr_transcript):
        mention_timestamp = number_mention["timestamp"]
        
        # 查找前后 10 秒内的图表
        chart_content = find_chart_at_time(
            video_features["chart_features"],
            mention_timestamp,
            tolerance_seconds=10
        )
        
        if chart_content:
            aligned_features["data_discussion_moments"].append({
                "timestamp": mention_timestamp,
                "asr_number": number_mention["value"],
                "chart_data": chart_content,
                "match_confidence": calculate_match_confidence(
                    number_mention["value"],
                    chart_content
                )
            })
    
    return aligned_features
```

#### 多模态置信度评估

```python
def calculate_multimodal_confidence(features, template):
    """
    计算多模态置信度
    如果多个信息源都支持同一判断，置信度更高
    """
    evidence_count = 0
    
    # ASR 证据
    if features["asr_features"]["meeting_type_prediction"]["confidence"] > 0.7:
        evidence_count += 1
    
    # PPT 证据
    if features["ocr_features"]["ppt_detected"]:
        ppt_topics = features["ocr_features"]["topics_from_slides"]
        predicted_type = features["meeting_type_prediction"]["predicted_type"]
        
        if predicted_type == "technical_review" and any("技术" in t for t in ppt_topics):
            evidence_count += 1
        elif predicted_type == "executive_meeting" and any("预算" in t for t in ppt_topics):
            evidence_count += 1
    
    # 图表证据
    if features["chart_features"]["charts_detected"]:
        evidence_count += 0.5
    
    # 场景证据
    scene_types = [s["scene_type"] for s in features["scene_features"]["scene_timeline"]]
    if predicted_type == "brainstorming" and "whiteboard" in scene_types:
        evidence_count += 1
    elif predicted_type == "executive_meeting" and "ppt_sharing" in scene_types:
        evidence_count += 0.5
    
    # 归一化到 0-1
    return min(evidence_count / 3.5, 1.0)
```

---

## 四、智能模板推荐

### 4.1 12 套 Prompt 模板库

| 模板 ID | 模板名称 | 适用场景 | 正式度 | 输出长度 | 关键特性 |
|--------|----------|----------|--------|----------|----------|
| `executive_business` | 高端商务版 | 董事会、高管会、决策会 | 极高 | 长 | 机密等级、决策依据、风险登记 |
| `technical_review` | 技术评审版 | 技术评审、架构评审 | 中 | 中 | 技术决策表、风险表、验收标准 |
| `client_meeting` | 客户沟通版 | 客户需求、商务谈判 | 高 | 中 | 需求汇总、承诺追踪、邮件模板 |
| `project_weekly` | 项目周会版 | 项目周会、进度同步 | 中 | 中 | 进度追踪、风险预警、下周计划 |
| `daily_standup` | 每日站会版 | 每日站会、快速同步 | 低 | 短 | 昨日完成、今日计划、阻塞问题 |
| `brainstorming` | 头脑风暴版 | 创意讨论、工作坊 | 低 | 中 | 创意分类、Top5 排序、验证计划 |
| `general_standard` | 通用标准版 | 一般会议、团队会议 | 中 | 中 | 决策、行动项、开放问题 |
| `general_minimal` | 极简版 | 快速同步、非正式会议 | 低 | 短 | 3 句总结、关键决策、行动项 |
| `bilingual_cn_en` | 中英双语版 | 国际会议、跨境团队 | 高 | 长 | 中英文双版本、术语对照 |
| `board_meeting` | 董事会专用版 | 董事会、股东会 | 极高 | 长 | 法律合规、逐字记录、投票记录 |
| `negotiation` | 商务谈判版 | 合同谈判、价格磋商 | 高 | 长 | 条款对比、双方承诺、待确认风险 |
| `workshop` | 工作坊版 | 培训工作坊、团建活动 | 低 | 中 | 活动记录、收获总结、改进计划 |

### 4.2 模板匹配算法

```python
def select_best_template_multimodal(features, templates):
    """
    基于多模态特征的模板推荐
    """
    scores = []
    
    for template in templates:
        score = 0
        match_reasons = []
        
        # 1. 会议类型匹配（权重 30%）
        predicted_type = features["meeting_type_prediction"]["predicted_type"]
        if predicted_type in template["suitable_for_meeting_types"]:
            score += 30
            match_reasons.append(f"会议类型匹配：{predicted_type}")
            
            # 多模态证据支持，额外加分
            evidence = features["meeting_type_prediction"]["multimodal_evidence"]
            if evidence["ppt_evidence"] or evidence["chart_evidence"]:
                score += 5
                match_reasons.append("PPT/图表内容支持该判断")
        
        # 2. PPT 关键信息匹配（权重 15%）
        if features["ocr_features"]["ppt_detected"]:
            ppt_features = features["ocr_features"]
            
            if len(ppt_features["decisions_on_slides"]) > 2:
                if template["expected_density"]["decision"] == "high":
                    score += 10
                    match_reasons.append(f"PPT 中包含{len(ppt_features['decisions_on_slides'])}个决策")
            
            if len(ppt_features["action_items_on_slides"]) > 3:
                if template["expected_density"]["action"] == "high":
                    score += 8
                    match_reasons.append(f"PPT 中包含{len(ppt_features['action_items_on_slides'])}个行动项")
        
        # 3. 图表数据匹配（权重 10%）
        if features["chart_features"]["charts_detected"]:
            chart_features = features["chart_features"]
            
            if len(chart_features["charts_detected"]) > 2:
                if "data_tables" in template["key_features"]:
                    score += 8
                    match_reasons.append(f"会议讨论了{len(chart_features['charts_detected'])}个图表")
        
        # 4. 场景分类匹配（权重 10%）
        scene_features = features["scene_features"]
        
        if any(s["scene_type"] == "whiteboard" for s in scene_features["scene_timeline"]):
            if template["template_id"] == "brainstorming":
                score += 10
                match_reasons.append("检测到白板讨论场景")
        
        # 5. ASR 特征匹配（权重 25%）
        asr_match_score = calculate_asr_match_score(features["asr_features"], template)
        score += asr_match_score
        
        # 6. 时长匹配（权重 10%）
        duration = features["meeting_metadata"]["actual_duration_minutes"]
        duration_match_score = calculate_duration_match(duration, template)
        score += duration_match_score
        
        scores.append({
            "template_id": template["template_id"],
            "template_name": template["name"],
            "score": score,
            "match_reasons": match_reasons,
            "multimodal_confidence": calculate_multimodal_confidence(features, template)
        })
    
    scores.sort(key=lambda x: x["score"], reverse=True)
    
    return {
        "best_match": scores[0],
        "alternatives": scores[1:3],
        "all_scores": scores
    }
```

### 4.3 推荐界面设计

```
┌──────────────────────────────────────────────────────────────┐
│  🤖 AI 已分析您的会议内容（多模态分析）                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  【会议特征分析】                                            │
│  • 预测会议类型：技术评审（置信度 92%）⬆️ 多模态证据支持     │
│  • 语言正式程度：中等                                        │
│  • 会议时长：45 分钟                                          │
│  • PPT 共享：检测到（18 页，覆盖 30 分钟）⬆️ 新增              │
│  • 图表讨论：检测到 3 个图表（柱状图 x2, 表格 x1）⬆️ 新增     │
│                                                              │
│  【ASR 内容分析】                                            │
│  • 技术术语密度：6.2%（高）                                  │
│  • 决策密度：中等（每 100 字 1.2 个决策）                      │
│  • 行动项密度：高（每 100 字 2.8 个行动项）                  │
│                                                              │
│  【PPT 内容分析】⬆️ 新增                                     │
│  • PPT 标题关键词：技术方案、风险评估、上线计划              │
│  • PPT 中的决策：2 个（"确定 9 月 10 日上线"）                  │
│  • PPT 中的行动项：5 个（"9/5 前完成测试"等）                 │
│                                                              │
│  【推荐模板】技术评审专用版 ⭐ 匹配度 94% ⬆️                 │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ 匹配原因：                                             │ │
│  │ ✓ ASR 分析：技术术语密度 6.2%                          │ │
│  │ ✓ PPT 分析：标题包含"技术方案"、"风险评估"              │ │
│  │ ✓ PPT 内容：包含 2 个决策、5 个行动项                     │ │
│  │ ✓ 图表分析：讨论了 3 个技术相关图表                     │ │
│  │ ✓ 多模态置信度：高（多个信息源支持同一判断）           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  [使用推荐模板] [手动选择] [自定义模板]                      │
└──────────────────────────────────────────────────────────────┘
```

---

## 五、AI 生成引擎

### 5.1 Prompt 动态组装

```python
def assemble_prompt(template_id, meeting_features, transcript):
    """
    根据选择的模板 ID 和会议特征，动态组装完整 Prompt
    """
    template = get_template(template_id)
    
    prompt_params = {
        "role_definition": get_role_definition(template_id, meeting_features),
        "task_description": get_task_description(template_id),
        "meeting_context": build_meeting_context(meeting_features),
        "transcript_text": transcript,
        "output_requirements": get_output_requirements(template_id, meeting_features),
        "quality_standards": get_quality_standards(template_id),
        "constraints": get_constraints(template_id),
        "examples": get_examples(template_id) if meeting_features["complexity"] == "high" else ""
    }
    
    prompt = template["base_prompt"].format(**prompt_params)
    return prompt

def get_role_definition(template_id, features):
    """根据模板类型和会议特征生成角色定义"""
    role_definitions = {
        "executive_business": f"""
你是一位资深的高管行政助理，拥有 10 年以上董事会秘书经验，擅长生成高端、专业、可执行的会议纪要。
本次会议是{features['meeting_type_prediction']['predicted_type']}，参会人员包括高管。
你的纪要文档将发送给公司高管和董事会成员，必须体现专业性和权威性。
        """,
        "technical_review": f"""
你是一位资深技术项目经理，擅长从技术评审会议中提取关键技术决策、风险点和行动项。
本次会议是技术评审会议，讨论内容包括技术架构、bug 修复、上线计划。
你生成的纪要被技术团队视为执行标准。
        """,
        "client_meeting": f"""
你是一位资深商务助理，擅长从客户沟通会议中提取关键承诺、条款和后续行动。
本次会议是客户会议，客户方包括多位代表。
你生成的纪要具有法律效力参考价值的严谨性。
        """
    }
    return role_definitions.get(template_id, DEFAULT_ROLE)
```

### 5.2 质量评估

```python
def assess_quality(minutes, transcript, template_id):
    """
    评估生成的会议纪要质量
    返回 0-100 的分数和质量问题列表
    """
    issues = []
    score = 100
    
    # 1. 决策提取完整性（25 分）
    transcript_decisions = extract_decisions_from_transcript(transcript)
    minutes_decisions = extract_decisions_from_minutes(minutes)
    decision_recall = len(minutes_decisions) / len(transcript_decisions) if transcript_decisions else 1
    
    if decision_recall < 0.8:
        score -= 15
        issues.append(f"可能遗漏决策：转写中提取到{len(transcript_decisions)}个决策，纪要中仅{len(minutes_decisions)}个")
    elif decision_recall < 0.9:
        score -= 5
        issues.append("决策提取基本完整，可能有少量遗漏")
    
    # 2. 行动项格式规范性（20 分）
    action_items = extract_action_items(minutes)
    formatted_count = sum(1 for ai in action_items if is_well_formatted(ai))
    
    if formatted_count < len(action_items) * 0.8:
        score -= 10
        issues.append("部分行动项格式不规范，缺少负责人或截止时间")
    
    # 3. 信息准确性（25 分）
    accuracy_issues = check_factual_accuracy(minutes, transcript)
    if accuracy_issues:
        score -= len(accuracy_issues) * 5
        issues.extend(accuracy_issues)
    
    # 4. 模板符合度（15 分）
    template_compliance = check_template_compliance(minutes, template_id)
    if not template_compliance["compliant"]:
        score -= 10
        issues.append(f"模板符合度不足：缺少{template_compliance['missing_sections']}")
    
    # 5. 语言质量（15 分）
    language_issues = check_language_quality(minutes)
    if language_issues:
        score -= len(language_issues) * 3
        issues.extend(language_issues)
    
    # 计算置信度等级
    if score >= 90:
        confidence = "High"
    elif score >= 70:
        confidence = "Medium"
    else:
        confidence = "Low"
    
    return {
        "score": max(0, score),
        "confidence": confidence,
        "issues": issues,
        "needs_human_review": score < 70 or confidence == "Low"
    }
```

---

## 六、数据结构设计

### 6.1 会议纪要表

```json
{
  "id": "uuid",
  "meeting_id": "uuid",
  "record_id": "uuid (关联会议记录)",
  "template_used": {
    "template_id": "executive_business",
    "template_name": "高端商务版",
    "auto_selected": true,
    "user_overridden": false,
    "selection_confidence": 0.92
  },
  "generation_metadata": {
    "ai_model": "gpt-4",
    "generation_time_seconds": 12.5,
    "prompt_length": 3500,
    "output_length": 2800,
    "quality_score": 88,
    "quality_confidence": "High",
    "needs_human_review": false,
    "reviewed_by": null,
    "reviewed_at": null
  },
  "content": {
    "title": "string",
    "summary": "text",
    "decisions": [
      {
        "id": "D-001",
        "topic": "string",
        "content": "text",
        "decision_maker": "string",
        "effective_date": "YYYY-MM-DD",
        "rationale": "text",
        "source_timestamp": "HH:MM:SS"
      }
    ],
    "action_items": [
      {
        "id": "A-001",
        "task": "string",
        "owner": "string",
        "due_date": "YYYY-MM-DD",
        "priority": "high|medium|low",
        "status": "not_started|in_progress|blocked|complete",
        "dependencies": ["string"],
        "success_criteria": "string",
        "source_timestamp": "HH:MM:SS"
      }
    ],
    "agenda_items": [...],
    "risks": [...],
    "open_questions": [...]
  },
  "formatting": {
    "visual_style": "premium",
    "color_scheme": "blue_professional",
    "font_family": "system",
    "output_formats": ["html", "pdf", "docx", "markdown"]
  },
  "status": "draft|published|approved",
  "approver": "string",
  "approved_at": "timestamp",
  "created_at": "timestamp",
  "updated_at": "timestamp"
}
```

### 6.2 多模态特征表

```json
{
  "id": "uuid",
  "meeting_id": "uuid",
  "asr_features": {
    "transcript_text": "string",
    "word_count": "number",
    "speaker_count": "number",
    "meeting_type_prediction": {
      "predicted_type": "string",
      "confidence": "number"
    },
    "formality_level": "low|medium|high",
    "decision_density": "number",
    "action_density": "number",
    "technical_density": "number",
    "business_density": "number"
  },
  "ocr_features": {
    "ppt_detected": "boolean",
    "total_slides": "number",
    "slide_titles": ["string"],
    "key_dates_on_slides": [
      {
        "date": "YYYY-MM-DD",
        "timestamp": "HH:MM:SS",
        "slide_number": "number",
        "context": "string"
      }
    ],
    "key_numbers_on_slides": [...],
    "decisions_on_slides": [...],
    "action_items_on_slides": [...]
  },
  "chart_features": {
    "charts_detected": [
      {
        "timestamp": "HH:MM:SS",
        "chart_type": "string",
        "title": "string",
        "data_summary": "string"
      }
    ],
    "data_discussion_moments": [...]
  },
  "scene_features": {
    "scene_timeline": [
      {
        "start_time": "HH:MM:SS",
        "end_time": "HH:MM:SS",
        "scene_type": "meeting_room|ppt_sharing|whiteboard",
        "description": "string"
      }
    ]
  },
  "aligned_features": {
    "decision_moments": [...],
    "data_discussion_moments": [...],
    "action_item_assignment_moments": [...]
  },
  "created_at": "timestamp"
}
```

---

## 七、API 设计

### 7.1 核心接口

#### 上传会议
```http
POST /api/meetings/upload
Content-Type: multipart/form-data

{
  "audio_file": "binary",
  "video_file": "binary (optional)",
  "metadata": {
    "title": "string",
    "scheduled_date": "YYYY-MM-DD",
    "scheduled_duration_minutes": "number"
  }
}

Response:
{
  "meeting_id": "uuid",
  "status": "processing",
  "estimated_completion_time": "2026-09-02T20:30:00Z"
}
```

#### 获取模板推荐
```http
GET /api/meetings/{meeting_id}/recommend-template

Response:
{
  "meeting_features": {
    "meeting_type_prediction": {
      "predicted_type": "technical_review",
      "confidence": 0.92
    },
    "formality_level": "medium",
    "actual_duration_minutes": 45,
    "ppt_detected": true,
    "charts_detected": 3
  },
  "recommendation": {
    "best_match": {
      "template_id": "technical_review",
      "template_name": "技术评审专用版",
      "match_score": 94,
      "match_reasons": [
        "会议类型匹配：技术评审",
        "PPT 包含 2 个决策、5 个行动项",
        "图表讨论 3 次",
        "多模态置信度：高"
      ]
    },
    "alternatives": [...]
  }
}
```

#### 生成会议纪要
```http
POST /api/meetings/{meeting_id}/generate-minutes
Content-Type: application/json

{
  "template_id": "technical_review",
  "output_formats": ["html", "pdf", "markdown"],
  "quality_threshold": 70
}

Response:
{
  "minutes_id": "uuid",
  "status": "generated",
  "template_used": {
    "template_id": "technical_review",
    "template_name": "技术评审专用版",
    "auto_selected": true
  },
  "generation_metadata": {
    "ai_model": "gpt-4",
    "generation_time_seconds": 12.5,
    "quality_score": 88,
    "quality_confidence": "High"
  },
  "output_urls": {
    "html": "/api/meetings/{id}/minutes/html",
    "pdf": "/api/meetings/{id}/minutes/pdf"
  }
}
```

---

## 八、实施路线图

### 8.1 分阶段实施

| 阶段 | 目标 | 关键功能 | 预计周期 |
|------|------|----------|----------|
| **Phase 1** | 基础 ASR 特征 | ASR 转写、关键词密度、会议类型预测 | 1 周 |
| **Phase 2** | 基础 OCR 功能 | PPT 检测、关键帧提取、文字 OCR | 2 周 |
| **Phase 3** | 多模态融合 | 时间对齐、内容关联、一致性检查 | 2 周 |
| **Phase 4** | 模板推荐 | 多模态匹配算法、推荐 UI | 1 周 |
| **Phase 5** | AI 生成 | Prompt 组装、LLM 调用、质量评估 | 2 周 |
| **Phase 6** | 图表识别 | 图表类型识别、数据提取 | 2 周 |
| **Phase 7** | 场景分类 | 场景识别、时间线生成 | 1 周 |
| **Phase 8** | 持续优化 | 用户反馈、模型迭代 | 持续 |

### 8.2 技术选型

| 模块 | 推荐方案 | 成本 |
|------|----------|------|
| **ASR 转写** | 讯飞听见 / 阿里云语音识别 | ¥5/小时 |
| **OCR 识别** | 百度 OCR / 腾讯 OCR | ¥2/小时 |
| **多模态 LLM** | GPT-4V / Claude 3 | ¥0.06/千 tokens |
| **图表识别** | DePlot / ChartOCR | 中 |
| **场景分类** | 自定义 ResNet 模型 | 中 |

### 8.3 成本效益分析

| 方案 | 成本 | 准确率 | 推荐场景 |
|------|------|--------|----------|
| **仅 ASR** | ¥5/小时 | 70-85% | 日常会议 |
| **ASR+ 基础 OCR** | ¥8/小时 | 80-90% | 常规会议 |
| **全量多模态** | ¥13/小时 | 85-95% | 重要会议 |

---

## 九、版本历史

| 版本 | 日期 | 更新内容 |
|------|------|----------|
| v1.0 | 2026-09-02 | 初始版本（依赖参会人信息，❌ 不可用） |
| v2.0 | 2026-09-02 | 改进版（仅基于 ASR，✅ 可用） |
| v3.0 | 2026-09-02 | 多模态融合版（ASR+OCR+ 视觉，✅ 推荐） |
| **v4.0** | **2026-09-02** | **完整整合版（所有设计文档融合）** |

---

## 十、配套文档

本文档是完整设计文档，配套以下 Prompt 模板库使用：

1. **AI 会议纪要 Prompt 模板库** (`AI_meeting_minutes_prompt_templates.md`)
   - 12 套会议纪要生成 Prompt
   - 基础版、进阶版、场景化版本

2. **多模态画面提取 Prompt 模板库** (`multimodal_meeting_visual_extraction_prompts.md`)
   - PPT 关键信息提取 Prompt
   - 图表数据提取 Prompt
   - 白板内容识别 Prompt
   - 场景分类 Prompt
   - 多模态融合分析 Prompt

---

**使用说明**：
1. 本文档是之前所有设计文档的完整整合版
2. 包含系统架构、特征提取、模板推荐、AI 生成、数据结构、API 设计等全部内容
3. 实施时建议按阶段推进，先实现基础 ASR 功能，再逐步增加 OCR 和多模态分析
4. Prompt 模板库作为独立文档，供 AI 生成引擎调用