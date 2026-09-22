# Interface design

Hearth is a workspace for an agency looking after homes and the people in them.
Its first screen answers: which homes are occupied, how much rent has arrived,
and which repairs need attention?

- Ink `#203451`, sidebar `#203c60`, blue `#294b77`, teal `#307b83`, sage `#527e6d`,
  background `#f3f6fa`. Error and pending colors only describe actual states.
- Restrained Avenir Next display typography with Trebuchet fallback, system body
  text and monospace for event IDs, versions and payloads. No remote font requests.
- A fixed desktop navigation rail and a scrolling mobile navigation row. Property
  drawings carry the visual identity; ledgers and forms remain quiet and legible.
- Architectural SVG illustrations, status chips and named repair conversations
  make the subject recognizable without stock photography.
- The console uses the same visual language, with entity kinds, versions, source
  cursors, action histories and expandable JSON in place of business summaries.
- Its independent store-health dashboard uses accessible SVG minute charts,
  per-entity rankings and explicit snapshot/control state labels. Zero-activity
  minutes stay visible; rate windows and all-time totals are labelled separately.

Names use quiet underlined links with complete native hover labels and accessible
names. Detail pages wrap full names, identity fields and JSON; chart labels and
bars link directly to their owning stream. The selected detail stays in place
when live updates arrive.

Keyboard focus is visible. SVG decoration is hidden from assistive technology;
property drawings have names. Fields have labels, feedback has a live region,
tables retain their headings and reduced-motion preferences are respected.
Live updates wait while an input is focused and preserve the chat composer.

The Operations workspace keeps the console palette and typography. Functional
groups form a compact left navigation; the right column shows labelled CLI fields,
examples, results and a session execution ledger. The connected store is a fixed
monospace strip above the form, so the target stays visible. Native required labels
and boolean choices expose the actual CLI contract; JSON and Raku source fields use
monospace textareas. Results retain form drafts, show diagnostics as text, and stop
polling when complete. Mobile stacks the form under a two-column operation menu.
