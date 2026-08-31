import { signOut } from '@/app/actions';

/**
 * An authenticated inspector who reaches the console is refused here rather
 * than shown an empty list. RLS would already withhold everyone else's work, so
 * this is not what keeps data safe — it is what keeps the answer honest: this
 * console is not for you, rather than "there is nothing to review".
 */
export default function NoAccessPage() {
  return (
    <main className="centre">
      <div className="panel">
        <h1>Not available</h1>
        <p className="sub" data-testid="no-access">
          This console is for reviewers. Your account does not have review
          access, so there is nothing here for you to see.
        </p>
        <form action={signOut}>
          <button className="primary" type="submit">
            Sign Out
          </button>
        </form>
      </div>
    </main>
  );
}
