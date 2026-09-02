import { signOut } from '@/app/actions';

/**
 * The console's frame: a fixed sidebar and a scrolling content column.
 *
 * Every page renders inside this, so the identity, the navigation and the two
 * standing facts about this product — that the console cannot write, and what
 * it is not connected to — are stated once and cannot drift between pages.
 *
 * The role label is not read from anywhere. `requireAdmin()` guards every page
 * that mounts this, so anyone seeing the shell is a reviewer by construction;
 * querying `profiles` again to print a word we already know would be a second
 * round trip that can only agree.
 */
export function AppShell({
  active,
  who,
  children,
}: {
  active: 'inspections' | 'photos';
  who: string | null;
  children: React.ReactNode;
}) {
  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">
            <ShieldMark />
          </span>
          <span>
            <span className="brand-name">FieldProof</span>
            <span className="brand-sub">Admin Portal</span>
          </span>
        </div>

        {/* Stated at the top of every page rather than discovered by pressing
            something. D3: there is no admin write policy at all, so this is a
            property of the database, not a UI mode. */}
        <p className="readonly-note">Read-only review console</p>

        <nav className="nav" aria-label="Sections">
          <NavLink href="/inspections" label="Inspections" active={active === 'inspections'}>
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
              <rect x="1" y="1" width="16" height="16" rx="3" stroke="currentColor" strokeWidth="1.5" />
              <path d="M1 5.5H17" stroke="currentColor" strokeWidth="1.5" />
              <path d="M1 9.5H17M1 13.5H17" stroke="currentColor" strokeWidth="1" strokeOpacity="0.6" />
            </svg>
          </NavLink>
          <NavLink href="/photos" label="Photos" active={active === 'photos'}>
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
              <rect x="1" y="3" width="16" height="12" rx="3" stroke="currentColor" strokeWidth="1.5" />
              <circle cx="6" cy="8" r="2" stroke="currentColor" strokeWidth="1.4" />
              <path d="M1 12L5 9L8 12L12 7L17 12" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
            </svg>
          </NavLink>
        </nav>

        {/* One place for what this prototype does not do, so the notes beside
            individual features stay short. Each line is a fact about the
            product, not a caveat about the demo data. */}
        <div className="about">
          <p className="about-title">About this prototype</p>
          <ul>
            <li>This console is read-only.</li>
            <li>PDF reports are generated on the inspector&rsquo;s device.</li>
            <li>Offline drafts sync when connectivity returns.</li>
            <li>Work-order assignment is not connected.</li>
          </ul>
        </div>

        <div className="who-box">
          <div className="who-row">
            <span className="avatar" aria-hidden="true">
              {initialsOf(who)}
            </span>
            <span className="who-text">
              <span className="who-name">{who ?? 'Signed in'}</span>
              <span className="who-role">Reviewer</span>
            </span>
          </div>
          <form action={signOut}>
            <button className="signout" type="submit">
              Sign Out
            </button>
          </form>
        </div>
      </aside>

      <div className="content">{children}</div>
    </div>
  );
}

function NavLink({
  href,
  label,
  active,
  children,
}: {
  href: string;
  label: string;
  active: boolean;
  children: React.ReactNode;
}) {
  return (
    <a className={active ? 'nav-item active' : 'nav-item'} href={href} aria-current={active ? 'page' : undefined}>
      {children}
      {label}
    </a>
  );
}

/** Up to two initials, or a dash when there is no name to take them from. */
function initialsOf(name: string | null): string {
  if (!name) return '—';
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '—';
  const letters = parts.slice(0, 2).map((p) => p[0]?.toUpperCase() ?? '');
  return letters.join('') || '—';
}

function ShieldMark() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
      <path d="M9 1L1.5 4.5V9C1.5 13.5 4.9 17.6 9 18.7C13.1 17.6 16.5 13.5 16.5 9V4.5L9 1Z" fill="currentColor" />
      <path d="M6 9.5L8 11.5L12.5 7" stroke="#fff" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
