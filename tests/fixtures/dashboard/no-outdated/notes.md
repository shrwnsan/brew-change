# no-outdated

Empty input record stream (0 lines). TTY render is a single line:

    No outdated packages.

No summary counts line, no groups, no action footer — there is nothing to act
on. Note for T2.5.3: the **piped** variant of this state stays byte-silent
(empty output), matching today's bare `brew-change`; the message is TTY-only.
