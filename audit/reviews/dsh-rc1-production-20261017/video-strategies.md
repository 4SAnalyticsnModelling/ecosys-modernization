# Retrieved video knowledge and implementation mapping

Primary video: [IBM Technology — Context Engineering for AI Agents: 4 Failure
Modes to Avoid](https://www.youtube.com/watch?v=BwXremQ-i6I), Martin Keen.
English auto-captions were successfully retrieved on2026-10-17 using yt-dlp,
after browser access failed. Caption source remains private in `.tmp/context-video/`;
this record summarizes rather than reproduces the transcript. Auto-captions
can contain transcription errors.

The four failure modes appear from4:35 onward; the remedies begin around7:32:

| Failure | Video strategy | Deployment response |
| --- | --- | --- |
| Incorrect notes become accepted facts | Validate conclusions against an observable source before remembering them | Global rules require test/source evidence, separate UNVERIFIED hypotheses from verified decisions, and avoid promoting issues into authoritative summary facts |
| Long history drives repetitive behavior | Compact carefully; keep detailed material in persistent files and retrieve it when needed | Full logs/spill files, continuous bounded output, loop detection, and the requested single75K summary trigger |
| Too many available tools confuse selection | Curate the tool set to the task and obtain more capabilities when needed | Minimal-preset/discovery guidance and measurement of schema count/bytes; no silent deletion of user capabilities |
| Old and corrected information coexist | Prune superseded assumptions or restate the corrected current state | Explicit supersession, current decision ledger and archives, with authoritative current notes preserved during compaction |

The video also warns that repeated summaries can drift. Accordingly, detailed
originals remain durable and verified notes are copied verbatim; summaries are
not treated as proof. Continuous head/tail trimming is a deployment choice,
not an algorithm or a numeric threshold prescribed by the video. It preserves
recoverability and requires reading omitted evidence before conclusions.

Additional primary reference: [IBM context engineering overview](https://www.ibm.com/think/topics/context-engineering).
