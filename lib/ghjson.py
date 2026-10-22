"""Filters for `gh api` JSON used by rune (lib/grimorios.sh). Reads stdin; `gh api --paginate` may print
several JSON documents back to back, which are read as one list. Standard library only; Python 3.8+.

Commands (TAB-separated output):
  repos ACCOUNT TOPIC OWNER...    repos with TOPIC owned by a trusted OWNER: full_name, clone_url, ACCOUNT
  invitations TOPIC OWNER...      repository invitations from a trusted OWNER (and with TOPIC when GitHub sends
                                  topics): id, full_name
  logins                          the `login` of each object (collaborators)
  invitees                        pending repository invitations: id, invitee login
"""

import json
import sys


def documents(text):
    dec, i, out = json.JSONDecoder(), 0, []
    while i < len(text):
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        value, i = dec.raw_decode(text, i)
        out.extend(value if isinstance(value, list) else [value])
    return [v for v in out if isinstance(v, dict)]


def owner(repo):
    return (repo.get("owner") or {}).get("login", "")


def main(argv):
    if not argv:
        sys.stdout.write(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        items = documents(sys.stdin.read())
    except ValueError as e:
        sys.stderr.write("ghjson: invalid JSON from gh: %s\n" % e)
        return 1
    if cmd == "repos" and len(args) >= 2:
        account, topic, owners = args[0], args[1], set(args[2:])
        for r in items:
            if owner(r) in owners and topic in (r.get("topics") or []) and r.get("full_name") and r.get("clone_url"):
                print("\t".join([r["full_name"], r["clone_url"], account]))
    elif cmd == "invitations" and len(args) >= 1:
        topic, owners = args[0], set(args[1:])
        for inv in items:
            repo = inv.get("repository") or {}
            topics = repo.get("topics")
            if owner(repo) in owners and (topics is None or topic in topics) and inv.get("id") and repo.get("full_name"):
                print("%s\t%s" % (inv["id"], repo["full_name"]))
    elif cmd == "logins":
        for u in items:
            if u.get("login"):
                print(u["login"])
    elif cmd == "invitees":
        for inv in items:
            login = (inv.get("invitee") or {}).get("login")
            if inv.get("id") and login:
                print("%s\t%s" % (inv["id"], login))
    else:
        sys.stderr.write("ghjson: unknown command or wrong arguments: %s\n" % " ".join(argv))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
