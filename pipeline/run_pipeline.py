"""Runs the SQL layers in order against a DuckDB file.

    python pipeline/run_pipeline.py --data-dir ../collections_30k_dataset --db data/collections.duckdb

Every file in sql/ is executed in filename order. {{DATA_DIR}} in the SQL is replaced with the
absolute path of the CSV folder. The script then prints the cleaning log so the Raw -> Rejected -> Golden
counts are visible straight away.
"""
import argparse
import pathlib
import duckdb

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default=str(ROOT.parent / "collections_30k_dataset"))
    ap.add_argument("--db", default=str(ROOT / "data" / "collections.duckdb"))
    ap.add_argument("--export", action="store_true", help="also write golden tables to data/golden/*.parquet")
    args = ap.parse_args()

    data_dir = pathlib.Path(args.data_dir).resolve().as_posix()
    db_path = pathlib.Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()  # always rebuild from raw so the run is reproducible

    con = duckdb.connect(str(db_path))
    for f in sorted((ROOT / "sql").glob("[0-9][0-9]_*.sql")):
        sql = f.read_text(encoding="utf-8").replace("{{DATA_DIR}}", data_dir)
        print(f"running {f.name}")
        con.execute(sql)

    print()
    print(con.sql("select dataset, step, rows_in, rows_out, rows_rejected, rows_corrected from dq.cleaning_log").df().to_string())

    if args.export:
        out = ROOT / "data" / "golden"
        out.mkdir(parents=True, exist_ok=True)
        for (t,) in con.execute("select table_name from information_schema.tables where table_schema='golden'").fetchall():
            con.execute(f"copy golden.{t} to '{(out / (t + '.parquet')).as_posix()}' (format parquet)")
        print("exported golden tables to", out)
    con.close()


if __name__ == "__main__":
    main()
