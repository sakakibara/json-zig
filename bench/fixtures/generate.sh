#!/bin/sh
# Regenerates medium.json and large.json. Output is fully deterministic
# (no timestamps, no randomness), so reruns are byte-identical.
set -eu
cd "$(dirname "$0")"

# medium.json: package-lock-like document - one big "packages" object of
# nested records with many short strings. Targets ~20 KB.
awk 'BEGIN {
  printf "{\n  \"name\": \"workspace-root\",\n  \"version\": \"3.0.0\",\n  \"lockfileVersion\": 3,\n  \"requires\": true,\n  \"packages\": {\n"
  n = 48
  for (i = 0; i < n; i++) {
    name = sprintf("pkg-%03d", i)
    major = i % 9; minor = (i * 7) % 20; patch = (i * 13) % 30
    printf "    \"node_modules/%s\": {\n", name
    printf "      \"version\": \"%d.%d.%d\",\n", major, minor, patch
    printf "      \"resolved\": \"https://registry.example.com/%s/-/%s-%d.%d.%d.tgz\",\n", name, name, major, minor, patch
    printf "      \"integrity\": \"sha512-%04x%04x%04x%04x%04x%04x%04x%04x%04x%04x%04x==\",\n", i*3+1, i*5+2, i*7+3, i*11+4, i*13+5, i*17+6, i*19+7, i*23+8, i*29+9, i*31+10, i*37+11
    printf "      \"license\": \"%s\",\n", (i % 3 == 0 ? "MIT" : (i % 3 == 1 ? "Apache-2.0" : "BSD-3-Clause"))
    printf "      \"engines\": {\n        \"node\": \">=%d\"\n      },\n", 14 + (i % 6) * 2
    printf "      \"dependencies\": {\n"
    deps = 2 + i % 3
    for (d = 0; d < deps; d++) {
      printf "        \"pkg-%03d\": \"^%d.%d.%d\"%s\n", (i + d * 17 + 1) % n, d % 4, (d * 3) % 10, (d * 5) % 10, (d < deps - 1 ? "," : "")
    }
    printf "      },\n"
    printf "      \"dev\": %s,\n", (i % 4 == 0 ? "true" : "false")
    printf "      \"hasInstallScript\": %s\n", (i % 11 == 0 ? "true" : "false")
    printf "    }%s\n", (i < n - 1 ? "," : "")
  }
  printf "  }\n}\n"
}' > medium.json

# large.json: a flat array of 1000 records mixing strings, ints, floats,
# bools, nulls, nested objects, and small arrays. Targets ~300 KB.
awk 'BEGIN {
  printf "[\n"
  n = 1000
  for (i = 0; i < n; i++) {
    printf "  {\n"
    printf "    \"id\": %d,\n", 100000 + i
    printf "    \"name\": \"user-%04d\",\n", i
    printf "    \"email\": \"user-%04d@example.com\",\n", i
    printf "    \"active\": %s,\n", (i % 7 == 0 ? "false" : "true")
    printf "    \"score\": %d.%02d,\n", (i * 37) % 100, (i * 53) % 100
    printf "    \"visits\": %d,\n", (i * i) % 10000
    printf "    \"referrer\": %s,\n", (i % 5 == 0 ? "null" : sprintf("\"https://example.com/campaign/%d\"", i % 23))
    printf "    \"tags\": [\"tier-%d\", \"region-%s\", \"cohort-%02d\"],\n", i % 4, (i % 2 == 0 ? "east" : "west"), i % 12
    printf "    \"address\": {\n"
    printf "      \"street\": \"%d Elm Street\",\n", 100 + i % 900
    printf "      \"city\": \"City-%02d\",\n", i % 50
    printf "      \"zip\": \"%05d\",\n", 10000 + (i * 97) % 90000
    printf "      \"geo\": { \"lat\": %d.%04d, \"lon\": -%d.%04d }\n", 30 + i % 20, (i * 31) % 10000, 70 + i % 50, (i * 41) % 10000
    printf "    }\n"
    printf "  }%s\n", (i < n - 1 ? "," : "")
  }
  printf "]\n"
}' > large.json
