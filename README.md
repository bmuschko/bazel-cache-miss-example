# Bazel cache miss example

A minimal Bazel 9 project that shows how an action writing the current timestamp into generated code defeats the cache for every action that consumes it.

The build has two `genrule` actions.
`//:build_info` generates the shell code `build_info.sh` with the project version and the current timestamp.
`//:app` consumes the generated code and bundles it with `src/main.sh` into the executable script `app.sh`.

## How a timestamp causes cache misses

Bazel looks up an action in the cache by its action key, a digest of the command line, the environment, and the contents of all input files.
The key is computed before the action runs, so it does not cover the outputs.

```starlark
genrule(
    name = "build_info",
    srcs = ["VERSION"],
    outs = ["build_info.sh"],
    cmd = ("{ echo \"BUILD_VERSION=$$(cat $(location VERSION))\"; " +
           "echo \"BUILD_TIMESTAMP=$$(date +%s)\"; } > $@"),
    tags = ["no-cache"],
)
```

`//:build_info` is tagged `no-cache`, so Bazel never stores or reuses its result and executes it on every build.
This stands in for any reason a producer executes again, for example a non-cacheable action, a build on another machine, or a change to one of its own inputs.
Every time it executes, `date` writes a different timestamp into `build_info.sh`.

`//:app` lists `build_info.sh` as an input, so a different timestamp means a different action key for `//:app` and a cache miss.
In a real project the consumers are compile and link actions, so one timestamp makes everything downstream rebuild.

Without the `no-cache` tag, the cache would return the first `build_info.sh` forever, because the action key of `//:build_info` never changes.

`.bazelrc` enables a disk cache in `~/.cache/bazel-cache-miss-example`, which survives `bazel clean` and simulates a shared remote cache.

## Prerequisites

Install [Bazelisk](https://github.com/bazelbuild/bazelisk).
It reads `.bazelversion` and downloads the pinned Bazel version on first use.
The commands below call `bazelisk`. If Bazelisk is installed as `bazel`, use that name instead.

Install [jq](https://jqlang.org/), which `scripts/diff-exec-logs.sh` uses to read the execution logs.

Watch the `INFO: N processes: ...` line near the end of each build's output.
On Linux the strategy is `linux-sandbox` or `processwrapper-sandbox` instead of `darwin-sandbox`, and output paths start with `bazel-out/k8-fastbuild` instead of `bazel-out/darwin_arm64-fastbuild`.

## Step 1: Build with an empty disk cache

```shell
rm -rf ~/.cache/bazel-cache-miss-example
bazelisk clean
bazelisk build //... --execution_log_json_file=/tmp/exec_log_1.json
```

Both actions execute because the cache is empty.

```
INFO: 3 processes: 1 internal, 2 darwin-sandbox.
```

The `--execution_log_json_file` flag writes every executed action, with its inputs, outputs and action key, to `/tmp/exec_log_1.json`.
Bazel sorts the actions, so the logs of two builds can be compared with a plain `diff`.

```shell
cat bazel-bin/build_info.sh
```

```
BUILD_VERSION=1.4.0
BUILD_TIMESTAMP=1794160418
```

## Step 2: Rebuild after a clean

`bazelisk clean` deletes the output base and the local action cache, just like a fresh CI runner or another developer's machine.
Only the disk cache is left to avoid executing actions.

```shell
bazelisk clean
bazelisk build //... --execution_log_json_file=/tmp/exec_log_2.json
```

Nothing in the workspace changed, yet both actions execute again.
`//:build_info` is never cached, and `//:app` misses the disk cache.

```
INFO: 3 processes: 1 internal, 2 darwin-sandbox.
```

The generated code now contains a different timestamp.

```shell
cat bazel-bin/build_info.sh
```

```
BUILD_VERSION=1.4.0
BUILD_TIMESTAMP=1794160419
```

Repeat this step as often as you like, the result is the same every time.

## Step 3: Compare the execution logs

```shell
diff -u /tmp/exec_log_1.json /tmp/exec_log_2.json
```

Ignore the differences under `metrics`, they only record timings.
`//:build_info` has the same inputs in both builds, but its output `build_info.sh` differs.
It has no action key in the log because it is not cacheable.

```diff
   "actualOutputs": [{
     "path": "bazel-out/darwin_arm64-fastbuild/bin/build_info.sh",
     "digest": {
-      "hash": "d17c2f1e3d54beb7162d3c1a012f58f9f473f1d6f4cb7a091743cfec91e71f2f",
+      "hash": "86201f6226ef8ef2e02dfcfdde8a1c5c8820952cbf95a99222af9f672d085f65",
       "sizeBytes": "47",
       "hashFunctionName": "SHA-256"
     },
```

`//:app` sees the changed `build_info.sh` as an input, which changes its action key, the `digest` after `targetLabel`.
That is the cache miss.

```diff
   "inputs": [{
     "path": "bazel-out/darwin_arm64-fastbuild/bin/build_info.sh",
     "digest": {
-      "hash": "d17c2f1e3d54beb7162d3c1a012f58f9f473f1d6f4cb7a091743cfec91e71f2f",
+      "hash": "86201f6226ef8ef2e02dfcfdde8a1c5c8820952cbf95a99222af9f672d085f65",
       "sizeBytes": "47",
       "hashFunctionName": "SHA-256"
     },
```

```diff
   "targetLabel": "//:app",
   "digest": {
-    "hash": "34d89a8a611200b12faf6ce7a2a1bdd31d0188202058c4efdba56b2f3c832059",
+    "hash": "f167552a80cb52b5948b7612234b1a5998b60b75a9e89c14522a630f208f25a3",
     "sizeBytes": "146",
     "hashFunctionName": "SHA256"
   },
```

`scripts/diff-exec-logs.sh` condenses the diff to the paths and action keys whose digests differ.

```shell
./scripts/diff-exec-logs.sh /tmp/exec_log_1.json /tmp/exec_log_2.json
```

```
action key of //:app
bazel-out/darwin_arm64-fastbuild/bin/app.sh
bazel-out/darwin_arm64-fastbuild/bin/build_info.sh
```

## Step 4: Apply the fix and build

Generated code should only depend on declared inputs.
Open `BUILD.bazel` and replace the `cmd` attribute of `//:build_info` with a command that only writes the version from the checked-in `VERSION` file.

```diff
-# Generates shell code that records when the build ran.
+# Generates shell code that records the version being built.
 genrule(
     name = "build_info",
     srcs = ["VERSION"],
     outs = ["build_info.sh"],
-    cmd = ("{ echo \"BUILD_VERSION=$$(cat $(location VERSION))\"; " +
-           "echo \"BUILD_TIMESTAMP=$$(date +%s)\"; } > $@"),
+    cmd = "echo \"BUILD_VERSION=$$(cat $(location VERSION))\" > $@",
     # Executes the action on every build instead of reusing a cached result.
     tags = ["no-cache"],
 )
```

Keep the `no-cache` tag, so `//:build_info` still executes on every build.

```shell
bazelisk build //... --execution_log_json_file=/tmp/exec_log_3.json
```

Both actions execute once more because the content of `build_info.sh` changed with the fix.

```
INFO: 3 processes: 1 internal, 2 darwin-sandbox.
```

```shell
cat bazel-bin/build_info.sh
```

```
BUILD_VERSION=1.4.0
```

If a build needs to record information like a timestamp or a commit, apply it to the final artifact in a step at the end of the build that is cheap to rerun, not to code that other actions consume.

## Step 5: Rebuild the fixed project after a clean

```shell
bazelisk clean
bazelisk build //... --execution_log_json_file=/tmp/exec_log_4.json
```

`//:build_info` still executes, but it produces the same `build_info.sh` as before.
`//:app` therefore has the same action key and is served from the disk cache.

```
INFO: 3 processes: 1 disk cache hit, 1 internal, 1 darwin-sandbox.
```

## Step 6: Compare the execution logs of the fixed project

```shell
diff -u /tmp/exec_log_3.json /tmp/exec_log_4.json
```

All digests are identical.
The only differences are the runner of `//:app`, which is now the disk cache, and the metrics.

```diff
-  "runner": "darwin-sandbox",
-  "cacheHit": false,
+  "runner": "disk cache hit",
+  "cacheHit": true,
```

`scripts/diff-exec-logs.sh` prints nothing.

```shell
./scripts/diff-exec-logs.sh /tmp/exec_log_3.json /tmp/exec_log_4.json
```

Run `git checkout -- BUILD.bazel` to restore the original project.

## GitHub Actions

The workflow in `.github/workflows/cache-miss-demo.yml` runs every step above as a separate workflow step on `ubuntu-latest` and `macos-latest`.
After each build, `scripts/verify-build.sh` fails the step if the number of executed actions or disk cache hits does not match.
The comparison steps fail if `scripts/diff-exec-logs.sh` does not report the expected differing digests.
