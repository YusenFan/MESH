# Method Draft

**Paper title:** Efficient and Accurate Multi-Hop Retrieval of Confidential Enterprise Knowledge in Trusted Execution Environments

> 作者说明：英文正文从方法总览开始，依次介绍核心模块、完整算法和必要实现细节。检索流程依据当前项目；TDX/H100 部分保留为 proposed deployment。文末中文说明不属于论文正文。

## III. METHOD

### A. Method Overview

LLM-Wiki Agent separates offline knowledge construction from online question answering. It organizes documents into three layers: source archives preserve document content, linked knowledge pages collect facts and their sources, and navigation summaries help locate relevant pages.

During construction, the LLM proposes facts and page relationships. The execution layer validates these proposals, preserves earlier knowledge, and writes the Wiki. It then groups related pages and builds a hybrid summary index.

During question answering, one LLM agent identifies the evidence it needs, reads candidate pages, and searches again for missing information. Each actual read returns evidence identifiers. The agent uses these identifiers to submit an answer, and the execution layer generates and checks its citations.

The method combines relationship-guided navigation, evidence-guided multi-hop retrieval, and bounded execution. Summaries guide page selection, while answers rely on text actually read. The proposed confidential deployment keeps document processing on a TDX CPU and model inference on a confidential H100 GPU.

### B. Source-Preserving Wiki Compilation

**1) Archiving and page selection:** Facts about the same entity or policy often appear in different documents. We compile them into reusable knowledge pages while retaining their sources. Each processed document is archived under its SHA256 content hash. Changed content creates a new archive entry.

For each document batch, a selection model receives the new documents and the existing page catalog. It selects relevant pages to update or link. The system reads these pages and their cited source documents before generating changes. An empty Wiki skips this selection step.

**2) Generation and validation:** The generation model receives the batch, selected pages, existing evidence, and allowed page types. It proposes page metadata, facts, source references, and related-page links. Each fact must cite at least one supplied source.

Before writing pages, the execution layer checks paths, sources, relationship targets, and update records. Every input document must appear among the cited sources, and all citations must refer to supplied evidence. Existing pages can be updated only if their contents were provided to the model.

Invalid proposals receive feedback for bounded correction. If batch validation still fails, the system can retry documents individually. Valid proposals are rendered as Markdown, and successful document versions are recorded for reuse. These checks validate references and structure; the model remains responsible for extracting supported facts.

**3) Incremental preservation:** New documents may add information, revise a policy, or conflict with earlier statements. The system preserves earlier facts and appends new ones. Each new fact on an existing page records its relation to prior knowledge: addition, elaboration, temporal update, correction, or conflict.

The record includes a reason, related earlier fact identifiers when required, and a source-supported validity time when available. This lets earlier and newer statements coexist without losing their sources. The resulting linked pages provide the input to summary construction and later evidence reading.

### C. Relationship-Guided Hybrid Navigation

**1) Overlapping page groups:** Supporting evidence may span several knowledge pages. To expose these pages together, we form a group from each page and its explicit Related Pages links:

$$
G_p=\{p\}\cup R(p),
\tag{1}
$$

where $R(p)$ contains the existing knowledge pages directly linked from page $p$. We deduplicate identical groups and remove strict subsets. For the unique candidate family $\mathcal{G}_0$, the retained groups are

$$
\mathcal{G}=\{G\in\mathcal{G}_0:
\nexists H\in\mathcal{G}_0\text{ with }G\subsetneq H\}.
\tag{2}
$$

Groups can overlap. For example, $\{A,B,C\}$ and $\{A,B,D\}$ both remain, while $\{A,B\}$ is removed. This preserves different contexts around shared pages. Grouping uses direct links rather than recursively merging all connected pages.

The LLM writes a navigation summary for each multi-page group. Singleton summaries are generated directly from their pages. The execution layer fixes membership and adds page links. A summary is used only when its membership and content fingerprint match the loaded Wiki snapshot.

**2) Hybrid retrieval:** Enterprise queries contain both exact terms and paraphrased descriptions. We therefore combine BM25 with dense retrieval over summary text. Long summaries are split into consecutive chunks. For a normalized encoder $e$, the dense score is the highest chunk similarity:

$$
D(q,s)=\max_j e(q)^{\mathsf T}e(c_{s,j}),
\tag{3}
$$

where $q$ is the query and $c_{s,j}$ is a chunk of summary $s$. The two rankings are combined through reciprocal rank fusion:

$$
F(q,s)=
\sum_{\substack{\ell\in\{\mathrm{BM25},\mathrm{dense}\}\\s\in L_\ell(q)}}
\frac{1}{k_{\mathrm{RRF}}+\operatorname{rank}_{\ell}(s)}.
\tag{4}
$$

Returned results are limited by count and token budgets. Each result includes member-page links for the next reading step. Unambiguous title or alias matches can also lead directly to pages. Directory browsing remains available when summaries miss useful content.

The hybrid index contains navigation summaries, not the full source archive. Summary text and retrieval scores guide selection; they do not provide final answer evidence.

### D. Evidence-State Multi-Hop Acquisition

**1) Tracking missing evidence:** A relevant page may support only one part of a multi-hop answer. The QA agent therefore maintains evidence requirements:

$$
\mathcal{R}_t=\{(r_j,u_j,z_j,I_j)\}_{j=1}^{m_t},
\tag{5}
$$

where $r_j$ is a requirement identifier, $u_j$ describes needed information, $z_j$ is unresolved or supported, and $I_j$ contains selected evidence identifiers. Requirements are updated by identifier, and omitted entries remain in the state.

The agent reads candidate pages and uses unresolved requirements to guide further retrieval. For bridge questions, an intermediate entity found in evidence can become the next query. For comparison questions, the agent gathers evidence for both entities. Knowledge pages can support answers directly; source passages are read when more detail or verification is needed.

**2) Evidence identifiers and citations:** Each actual read registers citable text for the current question. An evidence identifier maps to an exact quotation, content version, and page offsets or source line numbers. Truncated reads register only the delivered text. Summaries, directory listings, and relationship descriptions are navigation material.

The agent submits claims using these identifiers. The execution layer resolves them into citations. A factual answer requires at least one recorded requirement, support for every recorded requirement, and an evidence chain covering all their identifiers. Each claim must refer to a known requirement, and every selected evidence identifier must match text delivered during reading.

Rejected submissions return feedback to the same agent. It can gather more evidence or correct the submission while budget remains. If evidence is insufficient, it returns unknown. Validation checks provenance and recorded coverage; it does not prove that the agent found every necessary hop or that its reasoning is correct.

**3) Controlling retrieval cost:** Repeated search and model calls increase latency. We prepare and cache summary embeddings, pre-read a small page batch, and provide a combined search-and-read operation. This operation returns candidate navigation and selected page evidence together, avoiding an intervening model round. Requirement updates can also accompany answer submission.

Adaptive retrieval adjusts result limits and token budgets using unresolved requirements. It excludes seen summaries and already-read pages from new candidate selection. When a search yields no new summaries, the next batch can expand within the configured cap. Continuation offsets allow further reading of truncated pages.

The controller limits tool operations, model turns, returned tokens, and optional elapsed time. A combined search-and-read costs two operations when both stages run and one when only navigation runs. A pre-read batch costs one operation; initial navigation is recorded separately. Errors and rejected submissions also consume budget. The final operation is reserved for submission, and exhaustion without an accepted answer returns unknown.

### E. Confidential CPU–GPU Execution

Sensitive data appears throughout construction and retrieval, including in summaries, embeddings, prompts, and logs. The proposed deployment protects these intermediates as well as the original documents.

The application runs in an Intel TDX confidential VM. Document processing, retrieval, evidence tracking, and citation validation execute inside the guest. The LLM runtime uses an attached NVIDIA H100 in confidential-computing mode for inference. The embedding service also runs within the approved trusted boundary. [Intel TDX overview](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html)

Before sensitive processing begins, an owner-controlled verifier checks fresh CPU and GPU evidence against the approved policy. It verifies the guest configuration and the GPU assigned to the workload. The guest service key is bound to attestation, and the key-management service releases storage keys through the bound channel. A trusted loader checks the approved model manifest and weight hashes. [NVIDIA deployment requirements](https://docs.nvidia.com/enterprise-reference-architectures/deploying-proprietary-models-confidential-compute-self-hosted-vms/latest/required-capabilities.html)

User connections terminate inside the guest, and model APIs use guest-local endpoints. H100 transfers use encrypted bounce buffers over PCIe. The guest driver establishes an SPDM session with GPU firmware to support protected CPU–GPU communication. [NVIDIA confidential-computing white paper](https://docs.nvidia.com/nvidia-secure-ai-with-blackwell-and-hopper-gpus-whitepaper.pdf)

Documents, Wiki pages, embeddings, caches, and diagnostic outputs are stored on an encrypted volume. Processing starts only after verification and volume unlock. Failed attestation prevents key release and new sensitive tasks. Protection relies on the approved guest software and platform security mechanisms. This section describes a deployment design; the current retrieval prototype has not established these guarantees through hardware validation.

### F. End-to-End Algorithms and Implementation Details

Algorithm 1 constructs the reusable Wiki. Algorithm 2 gathers evidence and answers each question. In the confidential deployment, both run after the environment is verified and protected storage is unlocked.

**Algorithm 1. Wiki construction**

```text
Input: document collection, existing Wiki, construction limits
Output: updated Wiki, navigation index, build report

1  Reuse valid build records and archive pending documents by content hash.
2  For each pending document batch:
3      Select and read relevant existing pages and their source evidence.
4      Generate facts, source references, updates, and page relationships.
5      Validate the proposal and retry with feedback within the limit.
6      If valid, merge additions, preserve prior facts, and record success.
7      If batch validation still fails, retry documents individually.
8      Record unresolved failures.
9  Rebuild directory indexes and form direct page-neighborhood groups.
10 Deduplicate groups and remove strict subsets.
11 Build or reuse current summaries, with fixed member links.
12 Prepare or load the compatible hybrid summary index.
13 Return the Wiki, index, and build/summary coverage report.
```

**Algorithm 2. Multi-hop question answering**

```text
Input: question, Wiki snapshot, navigation index, execution budgets
Output: answer with citations, or unknown with diagnostics

1  Initialize one agent conversation, requirements, and evidence registry.
2  Obtain initial navigation and optionally pre-read a bounded page batch.
3  Register delivered evidence and charge any pre-read operation.
4  While model turns, tool operations, and time remain:
5      Provide requirements and remaining budget to the agent.
6      Reserve the final operation for answer submission.
7      Obtain the next response and process tool calls sequentially.
8      For search/read calls, execute within limits and register evidence.
9      For state updates, validate evidence IDs and merge requirements.
10     For submission, resolve IDs and check citations and coverage.
11     Charge operation costs, including failures and rejected submissions.
12     Return an accepted answer; otherwise pass feedback to the agent.
13 Return unknown with the termination reason and evidence state.
```

The current implementation uses BM25 parameters $k_1=1.5$ and $b=0.75$, RRF constant $k_{\mathrm{RRF}}=60$, and 20 candidates per ranking. Construction selects at most 15 existing pages and allows two corrective generation retries after the initial attempt.

The latency configuration pre-reads up to two pages and allows 15 tool operations and 17 model turns. Navigation and knowledge-page reads have separate 4,000-token return limits. The default question deadline is 120 seconds, checked during turns and requests. All settings are configurable.

Embeddings are cached by content and model configuration. Prepared vector snapshots are reused only when their fingerprints match. Dense retrieval scans the summary vectors locally. For $C$ chunks with dimension $d$, scanning takes $O(Cd)$ time, excluding query embedding and ranking. The implementation does not use ANN.

Full conversation history is retained, so per-call limits do not bound total prompt size. Experiments should report answer quality, evidence coverage, model calls, online latency, and index preparation separately. TEE overhead requires measurements on the confidential deployment.

---

## 作者核对说明（不属于论文正文）

正文保留六部分：A 方法总览；B Wiki 构建；C 关系导航与混合检索；D 多跳证据获取；E confidential execution；F 完整算法与实现细节。

贡献重点为关系驱动的重叠页面组、证据缺口驱动的单 Agent 循环，以及预读、缓存和组合操作。TDX/H100 表述保留为部署设计，不写成已完成的硬件验证。

| 正文                     | 实现依据                                                                                                                                                                                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B：构建与增量保留        | [bench_ingest.py](llm_wiki_bench/bench_ingest.py)、[wiki_documents.py](llm_wiki_bench/wiki_documents.py)、[knowledge_updates.py](llm_wiki_bench/knowledge_updates.py)                                                |
| C：分组与混合检索        | [build_summaries.py](llm_wiki_bench/build_summaries.py)、[summary_retrieval.py](llm_wiki_bench/summary_retrieval.py)、[embedding_client.py](llm_wiki_bench/embedding_client.py)                                      |
| D：Agent、阅读与证据校验 | [wiki_agent.py](llm_wiki_bench/wiki_agent.py)、[wiki_retriever.py](llm_wiki_bench/wiki_retriever.py)、[evidence_snapshots.py](llm_wiki_bench/evidence_snapshots.py)、[qa_contract.py](llm_wiki_bench/qa_contract.py) |
| E：部署设计              | [confidential-tee-deployment.md](docs/confidential-tee-deployment.md)                                                                                                                                                |
| F：运行配置              | [run_qa.py](llm_wiki_bench/run_qa.py)                                                                                                                                                                                |

Introduction 中的 hierarchy 对应摘要、知识页、原文三个功能层次；当前没有递归摘要树。混合检索使用导航摘要的 embeddings。问题分解由同一个 Agent 动态完成，不是独立的预处理模型。

正文中的文献链接应在论文主文件中转为 bibliography 引用，并补入 BM25、RRF 原始文献。实际实验参数与性能结论应以运行记录为依据。

论文插图：[无标题版本](docs/figures/confidential-wiki-architecture-paper.png)。前一版正文：[精简前备份](docs/method-history/METHOD-2026-10-11-before-concise-rewrite.md)。
