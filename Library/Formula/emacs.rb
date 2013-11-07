require 'formula'

class Emacs < Formula
  homepage 'http://www.gnu.org/software/emacs/'
  url 'http://ftpmirror.gnu.org/emacs/emacs-24.3.tar.gz'
  mirror 'http://ftp.gnu.org/pub/gnu/emacs/emacs-24.3.tar.gz'
  sha256 '0098ca3204813d69cd8412045ba33e8701fa2062f4bff56bedafc064979eef41'

  skip_clean 'share/info' # Keep the docs

  option "cocoa", "Build a Cocoa version of emacs"
  option "srgb", "Enable sRGB colors in the Cocoa version of emacs"
  option "with-x", "Include X11 support"
  option "use-git-head", "Use Savannah (faster) git mirror for HEAD builds"
  option "keep-ctags", "Don't remove the ctags executable that emacs provides"

  if build.include? "use-git-head"
    head 'http://git.sv.gnu.org/r/emacs.git'
  else
    head 'bzr://http://bzr.savannah.gnu.org/r/emacs/trunk'
  end

  if build.head? or build.include? "cocoa"
    depends_on :autoconf
    depends_on :automake
  end

  depends_on 'pkg-config' => :build
  depends_on :x11 if build.include? "with-x"
  depends_on 'gnutls' => :optional

  fails_with :llvm do
    build 2334
    cause "Duplicate symbol errors while linking."
  end

  def patches
    {
      # Fix default-directory on Cocoa and Mavericks.
      # Fixed upstream in r114730 and r114882.
      :p0 => fix_default_directory,
      # Make native fullscreen mode optional, mostly from
      # upstream r111679
      :p1 => [
        'https://gist.github.com/scotchi/7209145/raw/a571acda1c85e13ed8fe8ab7429dcb6cab52344f/ns-use-native-fullscreen-and-toggle-frame-fullscreen.patch',
        add_activity_hooks
      ]
    }
  end unless build.head?

  # Follow MacPorts and don't install ctags from Emacs. This allows Vim
  # and Emacs and ctags to play together without violence.
  def do_not_install_ctags
    unless build.include? "keep-ctags"
      (bin/"ctags").unlink
      (share/man/man1/"ctags.1.gz").unlink
    end
  end

  def install
    # HEAD builds blow up when built in parallel as of April 20 2012
    ENV.j1 if build.head?

    args = ["--prefix=#{prefix}",
            "--without-dbus",
            "--enable-locallisppath=#{HOMEBREW_PREFIX}/share/emacs/site-lisp",
            "--infodir=#{info}/emacs"]
    if build.with? 'gnutls'
      args << '--with-gnutls'
    else
      args << '--without-gnutls'
    end

    system "./autogen.sh" if build.head?

    if build.include? "cocoa"
      # Patch for color issues described here:
      # http://debbugs.gnu.org/cgi/bugreport.cgi?bug=8402
      if build.include? "srgb"
        inreplace "src/nsterm.m",
          "*col = [NSColor colorWithCalibratedRed: r green: g blue: b alpha: 1.0];",
          "*col = [NSColor colorWithDeviceRed: r green: g blue: b alpha: 1.0];"
      end

      args << "--with-ns" << "--disable-ns-self-contained"
      system "./configure", *args
      system "make"
      system "make install"
      prefix.install "nextstep/Emacs.app"

      # Don't cause ctags clash.
      do_not_install_ctags

      # Replace the symlink with one that avoids starting Cocoa.
      (bin/"emacs").unlink # Kill the existing symlink
      (bin/"emacs").write <<-EOS.undent
        #!/bin/bash
        #{prefix}/Emacs.app/Contents/MacOS/Emacs -nw  "$@"
      EOS
    else
      if build.include? "with-x"
        # These libs are not specified in xft's .pc. See:
        # https://trac.macports.org/browser/trunk/dports/editors/emacs/Portfile#L74
        # https://github.com/mxcl/homebrew/issues/8156
        ENV.append 'LDFLAGS', '-lfreetype -lfontconfig'
        args << "--with-x"
        args << "--with-gif=no" << "--with-tiff=no" << "--with-jpeg=no"
      else
        args << "--without-x"
      end

      system "./configure", *args
      system "make"
      system "make install"

      # Don't cause ctags clash.
      do_not_install_ctags
    end
  end

  def caveats
    s = ""
    if build.include? "cocoa"
      s += <<-EOS.undent
        Emacs.app was installed to:
          #{prefix}

         To link the application to a normal Mac OS X location:
           brew linkapps
         or:
           ln -s #{prefix}/Emacs.app /Applications

         A command line wrapper for the cocoa app was installed to:
          #{bin}/emacs
      EOS
    end
    return s
  end

  # Fix default-directory on Cocoa and Mavericks.
  # Fixed upstream in r114730 and r114882.
  def fix_default_directory
    StringIO.new <<-PATCH
--- src/emacs.c.orig	2013-02-06 13:33:36.000000000 +0900
+++ src/emacs.c	2013-11-02 22:38:45.000000000 +0900
@@ -1158,10 +1158,13 @@
   if (!noninteractive)
     {
 #ifdef NS_IMPL_COCOA
+      /* Started from GUI? */
+      /* FIXME: Do the right thing if getenv returns NULL, or if
+         chdir fails.  */
+      if (! inhibit_window_system && ! isatty (0))
+        chdir (getenv ("HOME"));
       if (skip_args < argc)
         {
-	  /* FIXME: Do the right thing if getenv returns NULL, or if
-	     chdir fails.  */
           if (!strncmp (argv[skip_args], "-psn", 4))
             {
               skip_args += 1;

    PATCH
  end

  def add_activity_hooks
    StringIO.new <<-PATCH
diff --git a/src/keyboard.c b/src/keyboard.c
index 47d8780..ef93dee 100644
--- a/src/keyboard.c
+++ b/src/keyboard.c
@@ -262,6 +262,9 @@ static Lisp_Object Qdeferred_action_function;

 static Lisp_Object Qdelayed_warnings_hook;

+static Lisp_Object Qactivate_emacs_hook;
+static Lisp_Object Qdeactivate_emacs_hook;
+
 static Lisp_Object Qinput_method_exit_on_first_char;
 static Lisp_Object Qinput_method_use_echo_area;

@@ -3986,6 +3989,16 @@ kbd_buffer_get_event (KBOARD **kbp,
 	  obj = make_lispy_event (event);
 	  kbd_fetch_ptr = event + 1;
 	}
+      else if (event->kind == ACTIVATE_EMACS_EVENT)
+      	{
+	  safe_run_hooks(Qactivate_emacs_hook);
+	  kbd_fetch_ptr = event + 1;
+	}
+      else if (event->kind == DEACTIVATE_EMACS_EVENT)
+      	{
+	  safe_run_hooks(Qdeactivate_emacs_hook);
+	  kbd_fetch_ptr = event + 1;
+	}
       else
 	{
 	  /* If this event is on a different frame, return a switch-frame this
@@ -11354,6 +11367,8 @@ syms_of_keyboard (void)
   DEFSYM (Qpre_command_hook, "pre-command-hook");
   DEFSYM (Qpost_command_hook, "post-command-hook");
   DEFSYM (Qdeferred_action_function, "deferred-action-function");
+  DEFSYM (Qactivate_emacs_hook, "activate-emacs-hook");
+  DEFSYM (Qdeactivate_emacs_hook, "deactivate-emacs-hook");
   DEFSYM (Qdelayed_warnings_hook, "delayed-warnings-hook");
   DEFSYM (Qfunction_key, "function-key");
   DEFSYM (Qmouse_click, "mouse-click");
@@ -11794,6 +11809,14 @@ the function in which the error occurred is unconditionally removed, since
 otherwise the error might happen repeatedly and make Emacs nonfunctional.  */);
   Vpost_command_hook = Qnil;

+  DEFVAR_LISP ("activate-emacs-hook",  Vactivate_emacs_hook,
+             doc: /* Normal hook run when emacs becomes active.*/);
+  Vactivate_emacs_hook = Qnil;
+
+  DEFVAR_LISP ("deactivate-emacs-hook",  Vdeactivate_emacs_hook,
+             doc: /* Normal hook run when emacs becomes inactive.*/);
+  Vdeactivate_emacs_hook = Qnil;
+
 #if 0
   DEFVAR_LISP ("echo-area-clear-hook", ...,
 	       doc: /* Normal hook run when clearing the echo area.  */);
diff --git a/src/nsterm.m b/src/nsterm.m
index a57e744..bb543f8 100644
--- a/src/nsterm.m
+++ b/src/nsterm.m
@@ -4519,7 +4519,24 @@ not_in_argv (NSString *arg)
   ns_update_auto_hide_menu_bar ();
   // No constraining takes place when the application is not active.
   ns_constrain_all_frames ();
+  if (!emacs_event)
+    return;
+
+  emacs_event->kind = ACTIVATE_EMACS_EVENT;
+  kbd_buffer_store_event (emacs_event);
+  ns_send_appdefined (-1);
 }
+
+- (void)applicationWillResignActive: (NSNotification *)notification
+{
+  if (!emacs_event)
+    return;
+
+  emacs_event->kind = DEACTIVATE_EMACS_EVENT;
+  kbd_buffer_store_event (emacs_event);
+  ns_send_appdefined (-1);
+}
+
 - (void)applicationDidResignActive: (NSNotification *)notification
 {
   //ns_app_active=NO;
diff --git a/src/termhooks.h b/src/termhooks.h
index a24b305..a95a7b6 100644
--- a/src/termhooks.h
+++ b/src/termhooks.h
@@ -210,6 +210,8 @@ enum event_kind
   , NS_TEXT_EVENT
   /* Non-key system events (e.g. application menu events) */
   , NS_NONKEY_EVENT
+  , ACTIVATE_EMACS_EVENT
+  , DEACTIVATE_EMACS_EVENT
 #endif

 };

    PATCH
  end

end
