# LocalFlow

Local dictation, transcript delivery, and optional recording retention.

## Language

**Dictation**:
A spoken utterance captured during one hotkey hold and converted to text.

**Captured recording**:
The recognition audio and optional original-rate audio from the same hold,
together with whether capture started successfully.

**Delivery**:
Sending a completed transcript to the focused app and resolving any clipboard
restoration. Dispatch does not prove that the target app inserted the text.

**Manual retry**:
A new recognition attempt using retained audio from a failed dictation and
current settings. It does not create another personal voice clip.

**Diagnostic recording**:
An optional, expiring archive of original audio, inference inputs, transcript
stages, and timing evidence for investigating dictation failures.

**Personal voice clip**:
A permanent local recording whose transcript requires explicit review and
approval before export. Automatic transcripts are not approved labels.
