#!/usr/bin/env python3
"""
GitHub Webhook Daemon for Autonomous Hermes Bug-Fixing Pipeline
Listens on localhost:8080, verifies HMAC signatures, and launches Hermes workflows.
"""

import os
import hmac
import hashlib
import json
import shutil
import subprocess
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

# Ensure user PATH and virtualenv binaries are accessible in non-interactive / systemd environments
user_home = os.path.expanduser("~")
extra_bin_paths = [
    os.path.join(user_home, ".local", "bin"),
    os.path.join(user_home, ".hermes", "hermes-agent", "venv", "bin"),
    os.path.join(user_home, ".hermes", "bin"),
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
]
current_path = os.environ.get("PATH", "")
os.environ["PATH"] = os.pathsep.join([p for p in extra_bin_paths if p] + [current_path])

# Propagate GitHub Personal Access Token to standard GH_TOKEN / GITHUB_TOKEN for gh CLI
github_pat = (
    os.getenv("GITHUB_PERSONAL_ACCESS_TOKEN")
    or os.getenv("GH_TOKEN")
    or os.getenv("GITHUB_TOKEN")
)
if github_pat:
    os.environ["GH_TOKEN"] = github_pat
    os.environ["GITHUB_TOKEN"] = github_pat

# Configuration (loaded from ~/.hermes/.env or environment)
WEBHOOK_SECRET = os.getenv("GITHUB_WEBHOOK_SECRET", "your-webhook-secret-token")
WEBHOOK_PORT = int(os.getenv("WEBHOOK_PORT", "8080"))
ALLOWED_REPOS = [
    repo.strip()
    for repo in os.getenv("HERMES_ALLOWED_REPOS", "piyushpatel2005/tutorial-k8s,piyushpatel2005/tutorial-python,piyushpatel2005/cpp-courses").split(",")
]
WORKSPACE_DIR = os.path.expanduser(os.getenv("HERMES_WORKSPACE_DIR", "~/workspace"))
LOG_DIR = os.path.expanduser(os.getenv("HERMES_LOG_DIR", "~/.hermes/logs"))

# Modular Feature Toggles (can be enabled/disabled via ~/.hermes/.env)
FEATURE_ISSUE_FIX = os.getenv("HERMES_FEATURE_ISSUE_FIX", "true").lower() == "true"
FEATURE_REQUIRE_LABEL = os.getenv("HERMES_FEATURE_REQUIRE_LABEL", "false").lower() == "true"
FEATURE_PR_COMMENT_FIX = os.getenv("HERMES_FEATURE_PR_COMMENT_FIX", "true").lower() == "true"
FEATURE_PR_INLINE_REVIEW_FIX = os.getenv("HERMES_FEATURE_PR_INLINE_REVIEW_FIX", "true").lower() == "true"
FEATURE_PR_REVIEW_FIX = os.getenv("HERMES_FEATURE_PR_REVIEW_FIX", "true").lower() == "true"

os.makedirs(WORKSPACE_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)


def ensure_gh_authenticated():
    """Idempotently ensures GitHub CLI is logged in and git credential helper is configured."""
    token = (
        os.getenv("GITHUB_PERSONAL_ACCESS_TOKEN")
        or os.getenv("GH_TOKEN")
        or os.getenv("GITHUB_TOKEN")
    )
    if not token:
        print("[Webhook Auth] Notice: No GitHub token found in environment.", flush=True)
        return

    # Check if gh CLI is already authenticated
    auth_check = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if auth_check.returncode != 0:
        print("[Webhook Auth] Authenticating gh CLI using environment token...", flush=True)
        login_res = subprocess.run(
            ["gh", "auth", "login", "--with-token"],
            input=token,
            capture_output=True,
            text=True
        )
        if login_res.returncode == 0:
            print("[Webhook Auth] Successfully authenticated gh CLI.", flush=True)
            subprocess.run(["gh", "auth", "setup-git"], capture_output=True, text=True)
        else:
            print(f"[Webhook Auth] Warning: gh login failed: {login_res.stderr.strip()}", flush=True)
    else:
        # Ensure git helper is configured
        subprocess.run(["gh", "auth", "setup-git"], capture_output=True, text=True)


class ReusableHTTPServer(HTTPServer):
    """HTTPServer subclass that enables socket SO_REUSEADDR for rapid service restarts."""
    allow_reuse_address = True


def verify_signature(payload: bytes, signature_header: str) -> bool:
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    expected = hmac.new(
        WEBHOOK_SECRET.encode("utf-8"), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(f"sha256={expected}", signature_header)


def get_default_branch(repo_dir: str) -> str:
    """Detects whether origin uses 'main', 'master', or a custom default branch."""
    try:
        res = subprocess.run(
            ["git", "-C", repo_dir, "symbolic-ref", "refs/remotes/origin/HEAD"],
            capture_output=True,
            text=True,
            check=True
        )
        return res.stdout.strip().split("/")[-1]
    except Exception:
        return "main"


def run_hermes_bugfix(repo_full_name: str, issue_number: int, issue_title: str, issue_body: str, issue_url: str):
    """
    Executes the full branch creation, bug fixing, test running, and PR opening pipeline.
    Safe for existing repositories in ~/workspace/: preserves existing work, pulls latest,
    and isolates bug fixes strictly inside a dedicated branch.
    """
    repo_name = repo_full_name.split("/")[-1]
    repo_dir = os.path.join(WORKSPACE_DIR, repo_name)
    branch_name = f"fix/issue-{issue_number}"
    log_file = os.path.join(LOG_DIR, f"webhook-task-issue-{issue_number}.log")

    with open(log_file, "a") as log:
        log.write(f"\n=======================================================\n")
        log.write(f"[{repo_full_name}] Processing Issue #{issue_number}: {issue_title}\n")
        log.write(f"Directory: {repo_dir} | Target Branch: {branch_name}\n")
        log.write(f"=======================================================\n\n")

        # 1. Clone repository if absent; preserve if present
        if not os.path.exists(os.path.join(repo_dir, ".git")):
            log.write(f"Repository not found locally. Cloning {repo_full_name} into {repo_dir}...\n")
            clone_res = subprocess.run(["gh", "repo", "clone", repo_full_name, repo_dir], stdout=log, stderr=log)
            if clone_res.returncode != 0:
                log.write(f"ERROR: Failed to clone repository {repo_full_name} (exit code {clone_res.returncode}). Check gh auth/token.\n")
                return
        else:
            log.write(f"Existing repository detected at {repo_dir}. Preserving local repo.\n")

        # 2. Check for any uncommitted operator changes and stash safely
        dirty_check = subprocess.run(
            ["git", "-C", repo_dir, "status", "--porcelain"],
            capture_output=True,
            text=True
        ).stdout.strip()

        stashed = False
        if dirty_check:
            log.write("Uncommitted changes detected in local repo. Stashing safely before update...\n")
            subprocess.run(
                ["git", "-C", repo_dir, "stash", "push", "-u", "-m", f"Auto-stash before Hermes fix issue #{issue_number}"],
                stdout=log,
                stderr=log
            )
            stashed = True

        # 3. Fetch latest upstream commits and determine default branch (main/master)
        log.write("Fetching latest updates from origin...\n")
        subprocess.run(["git", "-C", repo_dir, "fetch", "origin"], stdout=log, stderr=log)
        default_branch = get_default_branch(repo_dir)

        # 4. Checkout fresh default branch and pull latest changes
        log.write(f"Checking out and fast-forwarding base branch '{default_branch}'...\n")
        subprocess.run(["git", "-C", repo_dir, "checkout", default_branch], stdout=log, stderr=log)
        subprocess.run(["git", "-C", repo_dir, "pull", "--ff-only", "origin", default_branch], stdout=log, stderr=log)

        # 5. Create and switch to the dedicated bugfix branch
        log.write(f"Creating and switching to clean branch '{branch_name}'...\n")
        subprocess.run(["git", "-C", repo_dir, "checkout", "-B", branch_name], stdout=log, stderr=log)

        # 6. Formulate Hermes autonomous bugfix prompt
        prompt = (
            f"You are resolving Issue #{issue_number} in repository {repo_full_name}.\n"
            f"Title: {issue_title}\n\n"
            f"Description / Request:\n{issue_body}\n\n"
            f"Instructions:\n"
            f"1. Search repository files (markdown, source code, lesson files) to locate text, code, or permalinks referenced in the issue.\n"
            f"2. Apply the requested edits (e.g. reformatting paragraph instructions into bulleted lists, fixing bugs, or updating documentation).\n"
            f"3. Run existing tests or linter checks if present to verify your changes.\n"
            f"4. Ensure your edits are clean and no stray temporary files are left behind."
        )

        hermes_bin = shutil.which("hermes")
        log.write(f"Resolved Hermes binary: {hermes_bin}\n")
        log.write("Invoking Hermes Agent autonomously...\n")

        if not hermes_bin:
            log.write("ERROR: 'hermes' binary not found in PATH. Verify Hermes CLI installation.\n")
            hermes_exit_code = 127
        else:
            # Hermes one-shot autonomous execution (-z / --oneshot auto-bypasses approvals for scripts)
            hermes_cmd = [
                hermes_bin,
                "-z", prompt,
                "--in", repo_dir,
                "--yolo",
                "--accept-hooks"
            ]
            hermes_run = subprocess.run(
                hermes_cmd,
                cwd=repo_dir,
                stdout=log,
                stderr=log
            )
            hermes_exit_code = hermes_run.returncode
            log.write(f"Hermes execution completed with exit code: {hermes_exit_code}\n")

        # 7. Verify changes made by Hermes
        status = subprocess.run(
            ["git", "-C", repo_dir, "status", "--porcelain"],
            capture_output=True,
            text=True
        ).stdout.strip()

        if not status:
            log.write("No code changes produced by Hermes. Posting feedback comment on issue...\n")
            comment_body = (
                f"🤖 **Hermes Agent Status Update**\n\n"
                f"Hermes analyzed Issue #{issue_number} in `{repo_full_name}`, but no automated code edits were produced "
                f"(exit code: `{hermes_exit_code}`).\n\n"
                f"**Tips**:\n"
                f"- Ensure the issue specifies the exact file path or lesson file name to be modified.\n"
                f"- Check server task logs at `~/.hermes/logs/webhook-task-issue-{issue_number}.log` for details."
            )
            comment_res = subprocess.run(
                ["gh", "issue", "comment", str(issue_number), "--repo", repo_full_name, "--body", comment_body],
                stdout=log,
                stderr=log
            )
            log.write(f"gh issue comment exit code: {comment_res.returncode}\n")
            if comment_res.returncode != 0:
                log.write("WARNING: Failed to post GitHub issue comment. Check 'gh auth status' and verify token has 'Issues: Read and write' permissions.\n")
            return

        # 8. Commit and push the branch to GitHub
        log.write(f"Committing changes to branch '{branch_name}' and pushing to origin...\n")
        subprocess.run(["git", "-C", repo_dir, "add", "-A"], stdout=log, stderr=log)
        commit_msg = (
            f"fix(issue-{issue_number}): {issue_title}\n\n"
            f"Automated bug fix generated by Hermes Agent on OCI.\n"
            f"Resolves #{issue_number}"
        )
        subprocess.run(["git", "-C", repo_dir, "commit", "-m", commit_msg], stdout=log, stderr=log)
        subprocess.run(["git", "-C", repo_dir, "push", "-u", "origin", branch_name, "--force"], stdout=log, stderr=log)

        # 9. Create the Pull Request back on GitHub
        pr_body = (
            f"## Automated Fix for Issue #{issue_number}\n\n"
            f"**Issue**: [{issue_title}]({issue_url})\n\n"
            f"### Description of Changes\n"
            f"This Pull Request was autonomously created by **Hermes Agent on OCI** to resolve issue #{issue_number}.\n\n"
            f"- Base branch: `{default_branch}`\n"
            f"- Fix branch: `{branch_name}`\n\n"
            f"Closes #{issue_number}"
        )
        log.write("Submitting Pull Request via GitHub CLI...\n")
        pr_res = subprocess.run(
            [
                "gh", "pr", "create",
                "--repo", repo_full_name,
                "--base", default_branch,
                "--head", branch_name,
                "--title", f"fix(issue-{issue_number}): {issue_title}",
                "--body", pr_body
            ],
            capture_output=True,
            text=True
        )
        log.write(f"PR Result: {pr_res.stdout} {pr_res.stderr}\n")


def run_hermes_pr_feedback(repo_full_name: str, pr_number: int, branch_name: str, feedback_text: str, file_path: str = None, diff_hunk: str = None):
    """
    Applies review feedback on an existing Pull Request branch and pushes updates.
    """
    repo_name = repo_full_name.split("/")[-1]
    repo_dir = os.path.join(WORKSPACE_DIR, repo_name)
    log_file = os.path.join(LOG_DIR, f"webhook-task-pr-{pr_number}.log")

    with open(log_file, "a") as log:
        log.write(f"\n=======================================================\n")
        log.write(f"[{repo_full_name}] Processing PR #{pr_number} Review Feedback\n")
        log.write(f"Directory: {repo_dir} | Branch: {branch_name}\n")
        log.write(f"=======================================================\n\n")

        # 1. Ensure repo exists locally
        if not os.path.exists(os.path.join(repo_dir, ".git")):
            log.write(f"Repository not found locally. Cloning {repo_full_name}...\n")
            clone_res = subprocess.run(["gh", "repo", "clone", repo_full_name, repo_dir], stdout=log, stderr=log)
            if clone_res.returncode != 0:
                log.write(f"ERROR: Failed to clone repository {repo_full_name}.\n")
                return

        # 2. Resolve branch name if not provided
        if not branch_name:
            pr_view = subprocess.run(
                ["gh", "pr", "view", str(pr_number), "--repo", repo_full_name, "--json", "headRefName"],
                capture_output=True,
                text=True
            )
            try:
                branch_name = json.loads(pr_view.stdout).get("headRefName")
            except Exception:
                branch_name = None

        if not branch_name:
            log.write(f"ERROR: Could not resolve head branch for PR #{pr_number}.\n")
            return

        # 3. Fetch latest commits on the PR branch and checkout
        log.write(f"Fetching and checking out PR branch '{branch_name}'...\n")
        subprocess.run(["git", "-C", repo_dir, "fetch", "origin", branch_name], stdout=log, stderr=log)
        subprocess.run(["git", "-C", repo_dir, "checkout", branch_name], stdout=log, stderr=log)
        subprocess.run(["git", "-C", repo_dir, "pull", "--ff-only", "origin", branch_name], stdout=log, stderr=log)

        # 4. Formulate remediation prompt
        prompt = (
            f"You are modifying Pull Request #{pr_number} in repository {repo_full_name}.\n"
            f"Current Branch: {branch_name}\n\n"
            f"Reviewer Feedback / Requested Remediation:\n{feedback_text}\n\n"
        )
        if file_path:
            prompt += f"Target File: {file_path}\n"
        if diff_hunk:
            prompt += f"Context Diff Hunk:\n```diff\n{diff_hunk}\n```\n\n"

        prompt += (
            "Instructions:\n"
            "1. Search repository files to locate the code referenced in the feedback.\n"
            "2. Apply the requested corrections or improvements directly to the files on disk.\n"
            "3. Run existing tests or linter checks to verify the fix.\n"
            "4. Ensure your changes are clean and complete."
        )

        hermes_bin = shutil.which("hermes")
        log.write(f"Resolved Hermes binary: {hermes_bin}\n")
        log.write("Invoking Hermes Agent for PR review remediation (-z oneshot mode)...\n")

        if not hermes_bin:
            log.write("ERROR: 'hermes' binary not found in PATH.\n")
            return

        hermes_cmd = [
            hermes_bin,
            "-z", prompt,
            "--in", repo_dir,
            "--yolo",
            "--accept-hooks"
        ]
        hermes_run = subprocess.run(
            hermes_cmd,
            cwd=repo_dir,
            stdout=log,
            stderr=log
        )
        log.write(f"Hermes remediation completed with exit code: {hermes_run.returncode}\n")

        # 5. Check if changes were produced
        status = subprocess.run(
            ["git", "-C", repo_dir, "status", "--porcelain"],
            capture_output=True,
            text=True
        ).stdout.strip()

        if status:
            log.write(f"Committing and pushing remediation commits to '{branch_name}'...\n")
            subprocess.run(["git", "-C", repo_dir, "add", "-A"], stdout=log, stderr=log)
            commit_msg = f"fix(pr-{pr_number}): address review feedback\n\nAutomated remediation by Hermes Agent."
            subprocess.run(["git", "-C", repo_dir, "commit", "-m", commit_msg], stdout=log, stderr=log)
            subprocess.run(["git", "-C", repo_dir, "push", "origin", branch_name], stdout=log, stderr=log)

            reply = (
                f"🤖 **Hermes Agent Remediation Update**\n\n"
                f"I have addressed the review feedback and pushed new commit(s) to branch `{branch_name}`.\n\n"
                f"Please review the updated diff."
            )
            subprocess.run(
                ["gh", "pr", "comment", str(pr_number), "--repo", repo_full_name, "--body", reply],
                stdout=log,
                stderr=log
            )
            log.write("Remediation comment posted on PR successfully.\n")
        else:
            log.write("No code changes produced from review feedback.\n")
            reply = (
                f"🤖 **Hermes Agent Status**\n\n"
                f"Hermes processed the review comment on PR #{pr_number}, but no code changes were produced.\n\n"
                f"**Tip**: Ensure specific files or code lines are referenced in the comment."
            )
            subprocess.run(
                ["gh", "pr", "comment", str(pr_number), "--repo", repo_full_name, "--body", reply],
                stdout=log,
                stderr=log
            )


class WebhookHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        # Health check endpoint for monitoring
        if self.path in ("/", "/health", "/webhook"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","service":"hermes-github-webhook"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        sig = self.headers.get("X-Hub-Signature-256", "")
        if not verify_signature(body, sig):
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Forbidden: Invalid Signature")
            return

        event = self.headers.get("X-GitHub-Event", "")
        payload = json.loads(body.decode("utf-8"))
        repo = payload.get("repository", {}).get("full_name")

        print(f"[Webhook] Event '{event}' received for repo '{repo}'", flush=True)

        if repo not in ALLOWED_REPOS:
            print(f"[Webhook] Ignored: repo '{repo}' is not in HERMES_ALLOWED_REPOS: {ALLOWED_REPOS}", flush=True)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(f"Ignored: Repo {repo} not in allowlist".encode("utf-8"))
            return

        # 1. Process Issues (opened, edited, or labeled 'hermes-fix')
        if event == "issues":
            action = payload.get("action")
            issue = payload.get("issue", {})
            labels = [lbl.get("name") for lbl in issue.get("labels", [])]

            is_labeled_hermes = (action == "labeled" and payload.get("label", {}).get("name") == "hermes-fix") or ("hermes-fix" in labels)
            if action in ("opened", "edited") or is_labeled_hermes:
                issue_num = issue.get("number")
                title = issue.get("title")
                desc = issue.get("body") or ""
                url = issue.get("html_url")

                print(f"[Webhook] Launching Hermes task for issue #{issue_num} on {repo}...", flush=True)
                thread = threading.Thread(
                    target=run_hermes_bugfix,
                    args=(repo, issue_num, title, desc, url)
                )
                thread.start()

                self.send_response(202)
                self.end_headers()
                self.wfile.write(b"Accepted: Hermes task started")
                return

        # 2. Process PR Comments (issue_comment on a Pull Request)
        elif event == "issue_comment":
            action = payload.get("action")
            issue = payload.get("issue", {})
            comment = payload.get("comment", {})
            comment_body = comment.get("body", "")
            comment_user = comment.get("user", {}).get("login", "")

            # Only process comments on Pull Requests, created by human reviewers (avoid bot loops)
            is_pr = "pull_request" in issue
            is_bot = comment_body.startswith("🤖") or "[bot]" in comment_user or comment_user == "github-actions"

            if action == "created" and is_pr and not is_bot:
                pr_num = issue.get("number")
                print(f"[Webhook] Launching Hermes PR remediation for PR #{pr_num} on {repo}...", flush=True)

                thread = threading.Thread(
                    target=run_hermes_pr_feedback,
                    args=(repo, pr_num, None, comment_body)
                )
                thread.start()

                self.send_response(202)
                self.end_headers()
                self.wfile.write(b"Accepted: Hermes PR remediation started")
                return

        # 3. Process Inline PR Review Comments (pull_request_review_comment)
        elif event == "pull_request_review_comment":
            action = payload.get("action")
            pr = payload.get("pull_request", {})
            comment = payload.get("comment", {})
            comment_body = comment.get("body", "")
            comment_user = comment.get("user", {}).get("login", "")
            file_path = comment.get("path")
            diff_hunk = comment.get("diff_hunk")
            branch_name = pr.get("head", {}).get("ref")

            is_bot = comment_body.startswith("🤖") or "[bot]" in comment_user

            if action == "created" and not is_bot:
                pr_num = pr.get("number")
                print(f"[Webhook] Launching Hermes inline review fix for PR #{pr_num} ({file_path}) on {repo}...", flush=True)

                thread = threading.Thread(
                    target=run_hermes_pr_feedback,
                    args=(repo, pr_num, branch_name, comment_body, file_path, diff_hunk)
                )
                thread.start()

                self.send_response(202)
                self.end_headers()
                self.wfile.write(b"Accepted: Hermes inline PR fix started")
                return

        # 4. Process Submitted PR Reviews (pull_request_review)
        elif event == "pull_request_review":
            action = payload.get("action")
            review = payload.get("review", {})
            pr = payload.get("pull_request", {})
            review_body = review.get("body") or ""
            branch_name = pr.get("head", {}).get("ref")
            state = review.get("state") # 'changes_requested', 'commented'

            if action == "submitted" and review_body.strip() and state in ("changes_requested", "commented"):
                pr_num = pr.get("number")
                print(f"[Webhook] Launching Hermes review remediation for PR #{pr_num} (state: {state}) on {repo}...", flush=True)

                thread = threading.Thread(
                    target=run_hermes_pr_feedback,
                    args=(repo, pr_num, branch_name, review_body)
                )
                thread.start()

                self.send_response(202)
                self.end_headers()
                self.wfile.write(b"Accepted: Hermes PR review started")
                return

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK: Event ignored")


if __name__ == "__main__":
    try:
        ensure_gh_authenticated()
        server = ReusableHTTPServer(("127.0.0.1", WEBHOOK_PORT), WebhookHandler)
        print(f"Hermes GitHub Webhook receiver listening on 127.0.0.1:{WEBHOOK_PORT}...")
        server.serve_forever()
    except Exception as e:
        print(f"Failed to start webhook server on port {WEBHOOK_PORT}: {e}", flush=True)
        raise
