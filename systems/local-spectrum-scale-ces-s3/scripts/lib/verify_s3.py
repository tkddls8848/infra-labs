#!/usr/bin/env python3
"""Create an mms3 account/bucket and exercise put/get/list/delete over CES S3."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


class S3Client:
    def __init__(self, host: str, port: int, access_key: str, secret_key: str) -> None:
        self.host = host
        self.port = port
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = "us-east-1"
        self.service = "s3"
        self.context = ssl._create_unverified_context()  # Lab endpoint uses its generated certificate.

    @staticmethod
    def _sign(key: bytes, value: str) -> bytes:
        return hmac.new(key, value.encode("utf-8"), hashlib.sha256).digest()

    def request(
        self,
        method: str,
        bucket: str,
        key: str | None = None,
        *,
        query: dict[str, str] | None = None,
        payload: bytes = b"",
        expected: tuple[int, ...] = (200,),
    ) -> tuple[int, bytes]:
        now = dt.datetime.now(dt.timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")
        path = f"/{bucket}" + (f"/{key}" if key is not None else "")
        canonical_uri = urllib.parse.quote(path, safe="/-_.~")
        canonical_query = urllib.parse.urlencode(
            sorted((query or {}).items()), quote_via=urllib.parse.quote, safe="-_.~"
        )
        host_header = f"{self.host}:{self.port}"
        payload_hash = hashlib.sha256(payload).hexdigest()
        canonical_headers = (
            f"host:{host_header}\n"
            f"x-amz-content-sha256:{payload_hash}\n"
            f"x-amz-date:{amz_date}\n"
        )
        signed_headers = "host;x-amz-content-sha256;x-amz-date"
        canonical_request = "\n".join(
            [method, canonical_uri, canonical_query, canonical_headers, signed_headers, payload_hash]
        )
        scope = f"{date_stamp}/{self.region}/{self.service}/aws4_request"
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                amz_date,
                scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            ]
        )
        date_key = self._sign(("AWS4" + self.secret_key).encode("utf-8"), date_stamp)
        region_key = self._sign(date_key, self.region)
        service_key = self._sign(region_key, self.service)
        signing_key = self._sign(service_key, "aws4_request")
        signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        authorization = (
            f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        )
        url = f"https://{host_header}{canonical_uri}"
        if canonical_query:
            url += "?" + canonical_query
        request = urllib.request.Request(url, data=payload if method == "PUT" else None, method=method)
        request.add_header("Authorization", authorization)
        request.add_header("Host", host_header)
        request.add_header("x-amz-content-sha256", payload_hash)
        request.add_header("x-amz-date", amz_date)

        try:
            with urllib.request.urlopen(request, context=self.context, timeout=30) as response:
                status = response.status
                body = response.read()
        except urllib.error.HTTPError as error:
            status = error.code
            body = error.read()
        if status not in expected:
            raise RuntimeError(
                f"{method} {url} returned HTTP {status}; expected {expected}: "
                f"{body.decode('utf-8', errors='replace')}"
            )
        return status, body


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--uid", required=True, type=int)
    parser.add_argument("--gid", required=True, type=int)
    args = parser.parse_args()

    data_root = args.data_root.resolve(strict=True)
    suffix = secrets.token_hex(6)
    account = f"scale-lab-{suffix}"
    bucket = f"scale-lab-{suffix}"
    key = "functional-check.txt"
    access_key = secrets.token_hex(10).upper()
    secret_key = secrets.token_hex(20)
    base_path = (data_root / ".verification" / suffix).resolve()
    base_path.relative_to(data_root)
    bucket_path = base_path / "bucket"
    payload = f"IBM Storage Scale CES S3 functional check {suffix}\n".encode("utf-8")
    client = S3Client(args.host, args.port, access_key, secret_key)
    account_created = False
    bucket_created = False
    object_created = False

    base_path.mkdir(parents=True, mode=0o770)
    bucket_path.mkdir(mode=0o770)
    os.chown(base_path, args.uid, args.gid)
    os.chown(bucket_path, args.uid, args.gid)

    try:
        run(
            "mms3",
            "account",
            "create",
            account,
            "--uid",
            str(args.uid),
            "--gid",
            str(args.gid),
            "--newBucketsPath",
            str(base_path),
            "--accessKey",
            access_key,
            "--secretKey",
            secret_key,
        )
        account_created = True
        print(f"[PASS] mms3 created temporary account {account}")

        run(
            "mms3",
            "bucket",
            "create",
            bucket,
            "--accountName",
            account,
            "--filesystemPath",
            str(bucket_path),
        )
        bucket_created = True
        print(f"[PASS] mms3 created temporary bucket {bucket}")

        client.request("PUT", bucket, key, payload=payload)
        object_created = True
        print("[PASS] S3 PUT uploaded the object through the CES endpoint")

        _, downloaded = client.request("GET", bucket, key)
        if downloaded != payload:
            raise RuntimeError("S3 GET payload differs from the uploaded bytes")
        print("[PASS] S3 GET returned the exact uploaded bytes")

        _, listing = client.request("GET", bucket, query={"list-type": "2"})
        keys = [element.text for element in ET.fromstring(listing).iter() if element.tag.endswith("Key")]
        if key not in keys:
            raise RuntimeError(f"S3 LIST did not include {key}; returned keys: {keys}")
        print("[PASS] S3 LIST returned the uploaded object")

        client.request("DELETE", bucket, key, expected=(200, 204))
        object_created = False
        client.request("GET", bucket, key, expected=(404,))
        print("[PASS] S3 DELETE removed the object")
    except Exception as error:  # noqa: BLE001 - clear lab failure with cleanup below.
        print(f"[FAIL] CES S3 functional verification failed: {error}", file=sys.stderr)
        return_code = 1
    else:
        print(f"[PASS] CES S3 put/get/list/delete succeeded at https://{args.host}:{args.port}")
        return_code = 0
    finally:
        if object_created:
            try:
                client.request("DELETE", bucket, key, expected=(200, 204, 404))
            except Exception as cleanup_error:  # noqa: BLE001
                print(f"[WARN] object cleanup failed: {cleanup_error}", file=sys.stderr)
        if bucket_created:
            cleanup = run("mms3", "bucket", "delete", bucket, "--force", check=False)
            if cleanup.returncode != 0:
                print(f"[WARN] bucket cleanup failed: {cleanup.stderr.strip()}", file=sys.stderr)
        if account_created:
            cleanup = run("mms3", "account", "delete", account, check=False)
            if cleanup.returncode != 0:
                print(f"[WARN] account cleanup failed: {cleanup.stderr.strip()}", file=sys.stderr)
        shutil.rmtree(base_path, ignore_errors=True)

    return return_code


if __name__ == "__main__":
    raise SystemExit(main())

