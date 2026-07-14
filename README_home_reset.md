# Prepare and Save the Default `schuler` Home

Use these steps when the current reset template is empty and you want to configure the `schuler` account as the new default state.

## 1. Temporarily disable the automatic home reset

Run this command while logged in as the administrator account `itm`:

```bash
sudo touch /etc/home-reset.disabled
```

This prevents the system from overwriting the changes while you configure the `schuler` account.

## 2. Configure the `schuler` account

1. Log out from `itm`.
2. Log in as `schuler`.
3. Configure everything that should appear after every restart, including:
   - Browser settings
   - Desktop settings
   - Applications
   - Default files and folders
4. Log out from `schuler`.

## 3. Return to the administrator account

Log back in as `itm`.

Confirm that `schuler` has no running processes:

```bash
pgrep -a -u schuler
```

If this command returns no output, `schuler` is fully logged out.

## 4. Save the configured home as the default template

Run:

```bash
sudo /usr/local/sbin/save-user-home-default
```

This copies the current `/home/schuler` directory into:

```text
/var/lib/home-reset/schuler
```

## 5. Re-enable the automatic reset

Run:

```bash
sudo rm -f /etc/home-reset.disabled
```

## 6. Verify the saved template

Check its size:

```bash
sudo du -sh /var/lib/home-reset/schuler
```

The result should be larger than `4.0K`.

You can also inspect the files:

```bash
sudo ls -la /var/lib/home-reset/schuler
```

## 7. Reboot and test

Reboot the computer:

```bash
sudo reboot
```

After the reboot, log in as `schuler` and confirm that the configured browser, desktop, applications, and files are restored correctly.
