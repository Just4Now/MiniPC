---
name: skill_creator
description: Use when the user explicitly asks to create, save, write, update, or persist a new skill/SKILL.md.
---

# skill_creator

Use this skill only when the user explicitly wants to create or update a skill.

Goal
- Produce a complete `SKILL.md` file for the requested skill.
- Save it by calling `write_sandbox_file` with the target sandbox path and full markdown content.

Required SKILL.md format
```markdown
---
name: skill_name
description: One sentence describing exactly when this skill should be used.
---

# skill_name

Instructions for the agent when this skill is selected.
```

Rules
- The `name` must be short and stable. Use lowercase letters, numbers, `_`, or `-`.
- The `description` must describe matching conditions, not implementation details.
- The body must contain concrete behavior rules the agent should follow later.
- Do not create a skill if the user only asks a normal question.
- If the user did not provide enough information to define the skill, ask a concise clarifying question.
- If enough information is present, call:
  `Action: write_sandbox_file[{"relativePath":"skills/skill_name/SKILL.md","content":"<complete SKILL.md markdown>"}]`
- After the tool succeeds, return a short Final with the saved skill name.
