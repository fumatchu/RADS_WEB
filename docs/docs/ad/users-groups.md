# Users & Groups

Create and manage AD user accounts and security/distribution groups.

---

## Authentication Strip

Every Active Directory management page shares a Kerberos authentication strip at the top. You authenticate
once with the domain `Administrator` password, and that ticket is reused across Users & Groups, Computers,
CN/OU, Sites & Services, and Policy for the rest of the session — sign out from the same strip when you're
done.

---

## Users

The **Users** tile shows every AD user account. From the toolbar you can:

| Action | What it does |
|---|---|
| **+ Add User** | Create a new AD user account |
| **⇪ Bulk Import** | Import multiple users at once |
| **⇩ Bulk Export** | Export the current user list to CSV |
| **↻ Refresh** | Reload the list from AD |
| Search | Filter the list as you type |

### Bulk Actions

Select multiple users (checkboxes) to reveal a bulk action bar:

- **Enable** / **Disable** — toggle account status for every selected user
- **Edit Fields** — change a shared attribute across the selection
- **Add to Groups** — add every selected user to one or more groups
- **Move CN/OU** — relocate the selection to a different container
- **Primary Grp** — change the primary group for the selection
- **Delete** — remove the selected accounts

---

## Groups

Switch to the **Groups** tile to manage security and distribution groups the same way — create, search, and
manage membership.

---

## Next Step

➡️ [Computers](docs/ad/computers.md)
