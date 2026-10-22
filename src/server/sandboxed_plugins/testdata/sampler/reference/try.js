// The SDK reference's Try it: a Run button calls one of the sampler's operations as the
// person looking (publr.call, through the admin) and shows its answer, then the lines the
// sampler's code logged while it ran, its queued hooks and jobs included as they land; Show
// me asks the admin to walk its own pages (publr.tour). What each button does is the page's
// data, #sampler-data.
(() => {
  const data = JSON.parse(document.getElementById("sampler-data").textContent);
  const blocks = document.querySelectorAll('[id^="sampler-answer-"], [id^="sampler-log-"]');
  for (const block of blocks) block.style.display = "none";

  const show = (id, text) => {
    const block = document.getElementById(id);
    if (!block) return;
    block.textContent = text;
    block.style.display = "";
  };
  const newest = async () => {
    const answer = await window.publr.log(0);
    return answer.lines.length > 0 ? answer.lines[0].id : 0;
  };
  const clock = (at) => new Date(at).toLocaleTimeString();

  // Hooks on events and jobs run from the queue after the call: the log is read again for a
  // few seconds, so their lines join as they land.
  const follow = async (key, since) => {
    const seen = new Map();
    for (let round = 0; round < 10; round += 1) {
      await new Promise((done) => setTimeout(done, round === 0 ? 200 : 600));
      const answer = await window.publr.log(since).catch(() => ({ lines: [] }));
      for (const line of answer.lines) seen.set(line.id, line);
      const lines = [...seen.values()].sort((left, right) => left.id - right.id);
      const text = lines.map((line) => `${clock(line.at)}  ${line.call}\n  ${line.line}`);
      show(`sampler-log-${key}`, lines.length > 0 ? text.join("\n") : "Nothing logged yet.");
    }
  };

  const run = async (button) => {
    const key = button.value.split(":")[0];
    const asked = data.runs[button.value];
    if (!asked) return;
    const since = await newest().catch(() => 0);
    show(`sampler-answer-${key}`, `${asked.operation} ${JSON.stringify(asked.input)}\n…`);
    let answered;
    try {
      answered = JSON.stringify(await window.publr.call(asked.operation, asked.input), null, 2);
    } catch (error) {
      answered = `Refused: ${error.message}`;
    }
    show(`sampler-answer-${key}`, `${asked.operation} ${JSON.stringify(asked.input)}\n${answered}`);
    await follow(key, since);
  };

  document.addEventListener("click", (event) => {
    const button = event.target instanceof Element ? event.target.closest("button[name]") : null;
    if (!button) return;
    if (button.name === "sampler-run") run(button);
    if (button.name === "sampler-tour" && data.tours[button.value]) {
      window.publr.tour(data.tours[button.value]);
    }
  });
})();
