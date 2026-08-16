const runs = [
  { name: "CI", workflow: "Ruby 3.4 · ubuntu-latest", branch: "main", branchGroup: "main", event: "push", commit: "9f2a1c7", duration: "2m 14s", updated: "12 min ago", status: "success" },
  { name: "Security audit", workflow: "Dependency review", branch: "main", branchGroup: "main", event: "schedule", commit: "8d3b0f1", duration: "1m 08s", updated: "34 min ago", status: "success" },
  { name: "CI", workflow: "Ruby 3.2 · ubuntu-latest", branch: "release/0.3", branchGroup: "release", event: "push", commit: "7c1e4a9", duration: "3m 02s", updated: "1 hr ago", status: "failed" },
  { name: "Release audit", workflow: "Safety contract", branch: "main", branchGroup: "main", event: "workflow_dispatch", commit: "6a91d2e", duration: "4m 41s", updated: "2 hrs ago", status: "success" },
  { name: "CI", workflow: "Ruby 4.0 · ubuntu-latest", branch: "feature/flow", branchGroup: "feature", event: "pull_request", commit: "5e7b3c2", duration: "—", updated: "Running now", status: "in-progress" },
  { name: "Lint", workflow: "RuboCop", branch: "main", branchGroup: "main", event: "push", commit: "4f8a1b6", duration: "—", updated: "Running now", status: "in-progress" }
];

const state = { query: "", branch: "all", status: "all" };
const runRows = document.querySelector("#run-rows");
const emptyState = document.querySelector("#empty-state");
const runSummary = document.querySelector("#run-summary");
const toast = document.querySelector("#toast");
let toastTimer;

const escapeHtml = (value) => String(value).replace(/[&<>'"]/g, (character) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  "'": "&#39;",
  '"': "&quot;"
}[character]));

const statusIcon = (status) => {
  if (status === "success") return '<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="m5 10.5 3.2 3.2L15 7" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" /></svg>';
  if (status === "failed") return '<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="m7 7 6 6M13 7l-6 6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" /></svg>';
  return '<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M10 5v5l3 2" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /><circle cx="10" cy="10" r="6.5" stroke="currentColor" stroke-width="1.4" /></svg>';
};

const statusLabel = (status) => ({
  success: "Passed",
  failed: "Failed",
  "in-progress": "Running"
}[status]);

const renderRuns = () => {
  const filteredRuns = runs.filter((run) => {
    const searchable = `${run.name} ${run.workflow} ${run.branch} ${run.event} ${run.commit}`.toLowerCase();
    const matchesQuery = !state.query || searchable.includes(state.query.toLowerCase());
    const matchesBranch = state.branch === "all" || run.branchGroup === state.branch;
    const matchesStatus = state.status === "all" || run.status === state.status;
    return matchesQuery && matchesBranch && matchesStatus;
  });

  runRows.innerHTML = filteredRuns.map((run) => `
    <tr tabindex="0" data-run-name="${escapeHtml(run.name)}" data-run-status="${escapeHtml(statusLabel(run.status))}">
      <td data-label="Workflow">
        <div class="workflow-cell">
          <span class="run-status-icon ${run.status}">${statusIcon(run.status)}</span>
          <span class="workflow-name"><strong>${escapeHtml(run.name)}</strong><small>${escapeHtml(run.workflow)}</small></span>
        </div>
      </td>
      <td data-label="Branch"><span class="branch-cell"><strong>${escapeHtml(run.branch)}</strong><small>${escapeHtml(run.commit)}</small></span></td>
      <td data-label="Event"><span class="event-cell"><strong>${escapeHtml(run.event)}</strong><small>GitHub event</small></span></td>
      <td data-label="Duration"><span class="duration-cell">${escapeHtml(run.duration)}</span></td>
      <td data-label="Updated"><span class="updated-cell">${escapeHtml(run.updated)}</span></td>
      <td data-label="Status"><span class="status-label"><span class="status-dot ${run.status === "success" ? "success" : run.status === "failed" ? "failed" : "progress"}"></span>${escapeHtml(statusLabel(run.status))}</span></td>
    </tr>
  `).join("");

  emptyState.hidden = filteredRuns.length > 0;
  runRows.closest(".workflow-table").hidden = filteredRuns.length === 0;
  runSummary.textContent = filteredRuns.length === runs.length
    ? `Showing ${filteredRuns.length} of 128 runs`
    : `Showing ${filteredRuns.length} matching ${runs.length} recent runs`;
};

const showToast = (message) => {
  window.clearTimeout(toastTimer);
  toast.textContent = message;
  toast.classList.add("visible");
  toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 3200);
};

document.querySelector("#run-search").addEventListener("input", (event) => {
  state.query = event.target.value.trim();
  renderRuns();
});

document.querySelector("#branch-filter").addEventListener("change", (event) => {
  state.branch = event.target.value;
  renderRuns();
});

document.querySelectorAll("[data-status]").forEach((button) => {
  button.addEventListener("click", () => {
    state.status = button.dataset.status;
    document.querySelectorAll("[data-status]").forEach((filter) => {
      const active = filter === button;
      filter.classList.toggle("active", active);
      filter.setAttribute("aria-pressed", String(active));
    });
    renderRuns();
  });
});

document.querySelector("#clear-filters").addEventListener("click", () => {
  state.query = "";
  state.branch = "all";
  state.status = "all";
  document.querySelector("#run-search").value = "";
  document.querySelector("#branch-filter").value = "all";
  document.querySelector('[data-status="all"]').click();
});

document.querySelector("#run-workflow").addEventListener("click", () => {
  showToast("Workflow dispatch is ready for a GitHub API connection.");
});

document.querySelector("#open-workflows").addEventListener("click", () => {
  document.querySelector("#workflows").scrollIntoView({ behavior: "smooth", block: "center" });
  showToast("You are viewing the active workflows.");
});

document.querySelector("#load-more").addEventListener("click", () => {
  showToast("The full run history is available when the GitHub API is connected.");
});

runRows.addEventListener("click", (event) => {
  const row = event.target.closest("tr");
  if (!row) return;
  showToast(`${row.dataset.runName} · ${row.dataset.runStatus}`);
});

runRows.addEventListener("keydown", (event) => {
  if (event.key !== "Enter" && event.key !== " ") return;
  event.preventDefault();
  event.target.click();
});

renderRuns();
