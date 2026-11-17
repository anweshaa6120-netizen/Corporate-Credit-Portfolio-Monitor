# Corporate Credit Portfolio Monitor
#   make seed    generate the synthetic loan book (deterministic, seed 42)
#   make views   (re)create all SQL views and run the sanity checks
#   make report  execute report.ipynb headless -> reports/report.html
#   make all     seed + views + report
#   make clean   remove generated data and reports (keeps the virtualenv)

VENV   := .venv
PYTHON := $(VENV)/bin/python
DB     := data/portfolio.duckdb

.PHONY: all seed views report clean distclean

all: seed views report

# The marker file re-installs only when requirements.txt changes.
$(VENV)/.installed: requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet -r requirements.txt
	touch $@

seed: $(VENV)/.installed
	$(PYTHON) seed.py --db $(DB)

views: $(VENV)/.installed
	$(PYTHON) apply_views.py --db $(DB)

report: $(VENV)/.installed
	$(VENV)/bin/jupyter nbconvert --to html --execute report.ipynb \
		--output-dir reports --output report.html

clean:
	rm -rf data/*.duckdb data/*.duckdb.wal reports

distclean: clean
	rm -rf $(VENV)
