"""Manual hosted entry point for the v2 closed checkout layout report."""

from hosted_layout_census import main


if __name__ == "__main__":
    raise SystemExit(main(v2=True))
