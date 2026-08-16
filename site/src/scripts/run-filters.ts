const initRunFilters = () => {
  const rows = Array.from(document.querySelectorAll<HTMLTableRowElement>(".run-row"));
  const search = document.querySelector<HTMLInputElement>("#run-search");
  const branch = document.querySelector<HTMLSelectElement>("#branch-filter");
  const summary = document.querySelector<HTMLElement>("#run-summary");
  const empty = document.querySelector<HTMLElement>("#empty-state");
  const table = document.querySelector<HTMLTableElement>(".workflow-table");
  const toast = document.querySelector<HTMLElement>("#toast");
  const totalRuns = 128;
  let toastTimer: number | undefined;

  if (!search || !branch || !summary || !empty || !table || !toast) return;

  const showToast = (message: string) => {
    window.clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.add("visible");
    toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 3200);
  };

  const render = () => {
    const query = search.value.trim().toLowerCase();
    const selectedBranch = branch.value;
    const selectedStatus = document.querySelector<HTMLButtonElement>(".filter-chip.active")?.dataset.status ?? "all";
    let visible = 0;

    rows.forEach((row) => {
      const searchText = row.dataset.runSearch ?? "";
      const rowBranch = row.querySelector("[data-label='Branch']")?.textContent ?? "";
      const matchesQuery = !query || searchText.includes(query);
      const matchesBranch = selectedBranch === "all" || rowBranch.includes(selectedBranch === "feature" ? "feature/" : selectedBranch);
      const matchesStatus = selectedStatus === "all" || row.dataset.runStatus === selectedStatus;
      const isVisible = matchesQuery && matchesBranch && matchesStatus;
      row.hidden = !isVisible;
      if (isVisible) visible += 1;
    });

    table.hidden = visible === 0;
    empty.hidden = visible > 0;
    summary.textContent = visible === rows.length ? `Showing ${visible} of ${totalRuns} runs` : `Showing ${visible} matching recent runs`;
  };

  search.addEventListener("input", render);
  branch.addEventListener("change", render);

  document.querySelectorAll<HTMLButtonElement>(".filter-chip").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll<HTMLButtonElement>(".filter-chip").forEach((filter) => {
        const active = filter === button;
        filter.classList.toggle("active", active);
        filter.setAttribute("aria-pressed", String(active));
      });
      render();
    });
  });

  document.querySelector("#clear-filters")?.addEventListener("click", () => {
    search.value = "";
    branch.value = "all";
    document.querySelector<HTMLButtonElement>("[data-status='all']")?.click();
  });

  document.querySelectorAll<HTMLElement>("[data-toast]").forEach((element) => {
    element.addEventListener("click", () => showToast(element.dataset.toast ?? "Action is ready."));
  });

  rows.forEach((row) => {
    row.addEventListener("click", () => showToast(`${row.dataset.runName} · ${row.dataset.runStatus}`));
    row.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      row.click();
    });
  });

  render();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initRunFilters, { once: true });
} else {
  initRunFilters();
}
