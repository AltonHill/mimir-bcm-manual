# 15 — BCM User Accounts & Sudo Access

> **Prerequisites:** 02 (BCM head node up). Run as `root` on the head node.
> BCM users are backed by BCM's LDAP — accounts created here resolve on
> all managed nodes.
>
> **Keep it minimal.** Passing `id`, `groupid`, `homedirectory`,
> `loginshell` etc. on the `user add` line causes weird interactions
> with BCM's OpenLDAP backend (shell/ID/home weirdness). Just add the
> user and set a temp password — BCM assigns sane defaults.

## 15.1 — Prepare the account list

Copy the template and fill in real usernames (columns in order):

```bash
cp scripts/accounts-template.csv accounts.csv
```

```text
username,sudo
bcm-admin,yes
ops-01,yes
field-01,no
vendor-01,no
```

- **Dedupe first.** The source data for this section had one username
  twice and another with conflicting IDs — decide the authoritative
  list before creating anything.
- `sudo` = `yes` puts the user in the sudoers drop-in (15.2).

Generate:

```bash
scripts/generate-users.py accounts.csv > create-users.sh
bash -n create-users.sh   # syntax check
less create-users.sh      # review before running
```

Each line is deliberately minimal:

```bash
cmsh -q -c "user; add bcm-admin; set password <TEMP-BCM-ADMIN>; commit"
```

> **Password handling:** replace each `<TEMP-*>` with a temporary
> password per the site's policy. BCM forces a change on first login.
> Never store real passwords in docs, tickets, or chat.

Verify:

```bash
cmsh -c "user; list"
getent passwd bcm-admin      # from a managed node
id bcm-admin
```

## 15.2 — Sudo access (in the software image)

Generate the drop-in from the same CSV:

```bash
scripts/generate-users.py --sudoers accounts.csv > bcm-admins
cat bcm-admins   # review: only admins should be listed
```

Install it in the image the nodes actually boot:

```bash
cm-chroot-sw-img /cm/images/$IMG_GPU
cp /path/to/bcm-admins /etc/sudoers.d/bcm-admins
chown root:root /etc/sudoers.d/bcm-admins
chmod 0440 /etc/sudoers.d/bcm-admins
visudo -cf /etc/sudoers.d/bcm-admins
# expected: /etc/sudoers.d/bcm-admins: parsed OK
exit
```

Alternative for larger teams: one LDAP group + one rule
(`%bcm-admins ALL=(ALL:ALL) ALL`) instead of per-user lines.

Push to the nodes (one at a time, wait for `[ COMPLETED ]`):

```bash
cmsh -q -c "device; imageupdate -n <node> -w"
```

## 15.3 — Validate per user

```bash
U="<username>"; N="<node>"
ssh $U@$N        # change temp password on first login
sudo -l && sudo whoami   # expect: root
```

## Troubleshooting

- **User not found on node:** `cmsh -c "user; list"`, then check the
  node is on the intended image and LDAP/NSS is healthy.
- **Sudo syntax error:** `visudo -cf /etc/sudoers.d/bcm-admins`;
  drop-in must be `root:root` mode `0440`.
- **Weird shell/home/ID after creation:** you passed too many options
  to `user add` — delete the user and re-create with the minimal form
  in 15.1.
