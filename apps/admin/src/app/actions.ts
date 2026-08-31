'use server';

import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';

/**
 * Ordinary email/password auth. No sign-up: accounts are provisioned out of
 * band (D13), and an admin console is not the place to create them.
 *
 * The failure message is deliberately the same for a wrong password and an
 * unknown address — distinguishing them turns the sign-in form into a way to
 * enumerate who has an account.
 */
export async function signIn(formData: FormData): Promise<void> {
  const email = String(formData.get('email') ?? '').trim();
  const password = String(formData.get('password') ?? '');

  if (!email || !password) {
    redirect('/sign-in?error=Enter+your+email+and+password.');
  }

  const supabase = createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    redirect('/sign-in?error=Those+credentials+were+not+accepted.');
  }

  redirect('/inspections');
}

export async function signOut(): Promise<void> {
  const supabase = createClient();
  await supabase.auth.signOut();
  redirect('/sign-in');
}
