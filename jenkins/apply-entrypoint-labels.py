#!/usr/bin/env python3
"""Apply the Jenkins display names through an authenticated Jenkins CLI command."""

import argparse
import subprocess
import xml.etree.ElementTree as ET


LABELS = {
    "packaging": "测试服",
    "production": "正式服",
    "packaging/audioTranslation": "共用打包归档",
}


def main():
    parser = argparse.ArgumentParser(
        usage="%(prog)s -- java -jar jenkins-cli.jar -s URL -webSocket -auth @AUTH_FILE"
    )
    parser.add_argument("cli", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.cli or args.cli[0] != "--" or len(args.cli) < 2:
        parser.error("Pass the authenticated Jenkins CLI command after --")
    cli = args.cli[1:]

    for name, label in LABELS.items():
        command = [*cli, "get-job", name]
        config = ET.fromstring(subprocess.check_output(command, stdin=subprocess.DEVNULL))
        if config.findtext("displayName") != label:
            display_name = config.find("displayName")
            if display_name is None:
                display_name = ET.SubElement(config, "displayName")
            display_name.text = label
            subprocess.run(
                [*cli, "update-job", name],
                input=ET.tostring(config, encoding="UTF-8", xml_declaration=True),
                check=True,
            )
            updated = ET.fromstring(subprocess.check_output(command, stdin=subprocess.DEVNULL))
            if updated.findtext("displayName") != label:
                raise RuntimeError(f"Could not verify the display name for {name}")
        print(f"{name} → {label}")


if __name__ == "__main__":
    main()
