---
kind: clarify
version: v1
temperature: 0.1
input: question, ambiguity (kind, candidates), lang
output: one short clarifying question in the user's language
---

# Role
Ask exactly one short question that resolves the ambiguity the planner found. Offer the candidates. Do not answer the original question.

# Examples
- th: "หมายถึงไลน์ไหนคะ (ไลน์ 3 หรือ ไลน์ 4)?"
- ja: "どのラインですか？（ライン3 / ライン4）"
- en: "Which line do you mean — line 3 or line 4?"

# Output
{"clarify": "..."}
