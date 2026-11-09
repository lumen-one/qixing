# 外部参考

这里放的是别的项目的研读笔记和配套教学材料，不是本项目的口径。改代码、改文档之前该看
什么，以 [文档规则与索引](../AGENTS.md) 与两份正文为准；未来方向看 [roadmap.md](../roadmap.md)。

| 文件 | 装什么 |
|---|---|
| [deepseek-harness-doc-management.md](deepseek-harness-doc-management.md) | deepseek-harness 文档管理策略的研读笔记：它解决什么问题、规则为什么这么定；末节评估了本项目能抄什么 |
| [deepseek-harness-doc-map.md](deepseek-harness-doc-map.md) | 同一项目的文档地图，按目录导览，配合上一份读 |
| [doc-management-course.md](doc-management-course.md) | 配套教学大纲，末讲落到本项目 |

三份都写于 2026-10-21 前后，是当时的评估材料。里面针对本项目提的建议（给正文加词数
上限、门禁脚本的骨架等）没有全部采纳，未勾选的清单也不是待办；现行门禁真正查什么，以
[`tool/doc_lint.dart`](../../tool/doc_lint.dart) 和 [`test/doc_lint_test.dart`](../../test/doc_lint_test.dart)
为准。别照这里的方案改仓库，也别把这里的描述当成现状。

这几份文件按外部参考对待：死链照查，状态词与版本号检查豁免（外部项目会引用自己的版本）。
