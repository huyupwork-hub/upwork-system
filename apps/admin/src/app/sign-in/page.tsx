import { signIn } from '@/app/actions';

/**
 * A server component with a plain form posting to a server action — no client
 * bundle, no state library. The error comes back in the query string because
 * that survives a full page navigation, which is all this form does.
 */
export default function SignInPage({
  searchParams,
}: {
  searchParams: { error?: string };
}) {
  const error = searchParams?.error;

  return (
    <main className="centre">
      <div className="panel">
        <h1>FieldProof Review</h1>
        <p className="sub">Sign in to review submitted inspections.</p>

        {error ? (
          <p className="error" data-testid="signin-error">
            {error}
          </p>
        ) : null}

        <form action={signIn}>
          <label htmlFor="email">Email</label>
          <input id="email" name="email" type="email" autoComplete="username" required />

          <label htmlFor="password">Password</label>
          <input
            id="password"
            name="password"
            type="password"
            autoComplete="current-password"
            required
          />

          <button className="primary" type="submit">
            Sign In
          </button>
        </form>
      </div>
    </main>
  );
}
