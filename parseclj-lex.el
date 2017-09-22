;;; parseclj-lex.el --- Clojure/EDN Lexer

;; Copyright (C) 2017  Arne Brasseur

;; Author: Arne Brasseur <arne@arnebrasseur.net>

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; A reader for EDN data files and parser for Clojure source files.

;;; Code:

(defvar parseclj-lex--leaf-tokens '(:whitespace
                                    :comment
                                    :number
                                    :nil
                                    :true
                                    :false
                                    :symbol
                                    :keyword
                                    :string
                                    :character)
  "Types of tokens that represent leaf nodes in the AST.")

(defvar parseclj-lex--closing-tokens '(:rparen
                                       :rbracket
                                       :rbrace)
  "Types of tokens that mark the end of a non-atomic form.")


(defun parseclj-lex-token (type form pos &rest attributes)
  "Create a lexer token with the specified attributes.

Tokens at a mimimum have these attributes
- TYPE: the type of token, like :whitespace or :lparen
- FORM: the source form, a string
- POS: the position in the input, starts from 1 (like point)

Other ATTRIBUTES can be given as a flat list of key-value pairs."
  (apply 'a-list :token-type type :form form :pos pos attributes))

(defun parseclj-lex-token? (token)
  "Is the given TOKEN a parseclj-lex TOKEN.

A token is an association list with :token-type as its first key."
  (and (consp token)
       (consp (car token))
       (eq :token-type (caar token))))

(defun parseclj-lex-token-type (token)
  "Get the type of TOKEN."
  (and (consp token)
       (cdr (assq :token-type token))))

(defun parseclj-lex-leaf-token? (token)
  "Return t if the given AST TOKEN is a leaf node."
  (member (parseclj-lex-token-type token) parseclj-lex--leaf-tokens))

(defun parseclj-lex-closing-token? (token)
  "Return t if the given ast TOKEN is a closing toking."
  (member (parseclj-lex-token-type token) parseclj-lex--closing-tokens))

(defun parseclj-lex-at-whitespace? ()
  "Return t if char at point is white space."
  (let ((char (char-after (point))))
    (or (equal char ?\ )
        (equal char ?\t)
        (equal char ?\n)
        (equal char ?\r)
        (equal char ?,))))

(defun parseclj-lex-at-eof? ()
  "Return t if point is at the end of file."
  (eq (point) (point-max)))

(defun parseclj-lex-whitespace ()
  "Consume all consecutive white space as possible and return an :whitespace token."
  (let ((pos (point)))
    (while (parseclj-lex-at-whitespace?)
      (right-char))
    (parseclj-lex-token :whitespace
                        (buffer-substring-no-properties pos (point))
                        pos)))

(defun parseclj-lex-skip-digits ()
  "Skip all consecutive digits after point."
  (while (and (char-after (point))
              (<= ?0 (char-after (point)))
              (<= (char-after (point)) ?9))
    (right-char)))

(defun parseclj-lex-skip-number ()
  "Skip a number at point."
  ;; [\+\-]?\d+\.\d+
  (when (member (char-after (point)) '(?+ ?-))
    (right-char))

  (parseclj-lex-skip-digits)

  (when (eq (char-after (point)) ?.)
    (right-char))

  (parseclj-lex-skip-digits))

(defun parseclj-lex-number ()
  "Consume a number and return a :number token."
  (let ((pos (point)))
    (parseclj-lex-skip-number)

    ;; 10110r2 or 4.3e+22
    (when (member (char-after (point)) '(?E ?e ?r))
      (right-char))

    (parseclj-lex-skip-number)

    ;; trailing M
    (when (eq (char-after (point)) ?M)
      (right-char))

    (let ((char (char-after (point))))
      (if (and char (or (and (<= ?a char) (<= char ?z))
                        (and (<= ?A char) (<= char ?Z))
                        (and (member char '(?. ?* ?+ ?! ?- ?_ ?? ?$ ?& ?= ?< ?> ?/)))))
          (progn
            (right-char)
            (parseclj-lex-token :lex-error
                                (buffer-substring-no-properties pos (point))
                                pos
                                :error-type :invalid-number-format))

        (parseclj-lex-token :number
                            (buffer-substring-no-properties pos (point))
                            pos)))))


(defun parseclj-lex-digit? (char)
  "Return t if CHAR is a digit."
  (and char (<= ?0 char) (<= char ?9)))

(defun parseclj-lex-at-number? ()
  "Return t if point is at a number."
  (let ((char (char-after (point))))
    (or (parseclj-lex-digit? char)
        (and (member char '(?- ?+ ?.))
             (parseclj-lex-digit? (char-after (1+ (point))))))))

(defun parseclj-lex-symbol-start? (char &optional alpha-only)
  "Return t if CHAR is a valid start for a symbol.

Symbols begin with a non-numeric character and can contain alphanumeric
characters and . * + ! - _ ? $ % & = < >.  If - + or . are the first
character, the second character (if any) must be non-numeric.

In some cases, like in tagged elements, symbols are required to start with
alphabetic characters only.  ALPHA-ONLY ensures this behavior."
  (not (not (and char
                 (or (and (<= ?a char) (<= char ?z))
                     (and (<= ?A char) (<= char ?Z))
                     (and (not alpha-only) (member char '(?. ?* ?+ ?! ?- ?_ ?? ?$ ?% ?& ?= ?< ?> ?/))))))))

(defun parseclj-lex-symbol-rest? (char)
  "Return t if CHAR is a valid character in a symbol.
For more information on what determines a valid symbol, see
`parseclj-lex-symbol-start?'"
  (or (parseclj-lex-symbol-start? char)
      (parseclj-lex-digit? char)
      (eq ?: char)
      (eq ?# char)))

(defun parseclj-lex-get-symbol-at-point (pos)
  "Return a string containing the symbol at POS."
  (while (parseclj-lex-symbol-rest? (char-after (point)))
    (right-char))
  (buffer-substring-no-properties pos (point)))

(defun parseclj-lex-symbol ()
  "Return a lex token representing a symbol.
Because of their special meaning, symbols \"nil\", \"true\", and \"false\"
are returned as their own lex tokens."
  (let ((pos (point)))
    (right-char)
    (let ((sym (parseclj-lex-get-symbol-at-point pos)))
      (cond
       ((equal sym "nil") (parseclj-lex-token :nil "nil" pos))
       ((equal sym "true") (parseclj-lex-token :true "true" pos))
       ((equal sym "false") (parseclj-lex-token :false "false" pos))
       (t (parseclj-lex-token :symbol sym pos))))))

(defun parseclj-lex-string ()
  "Return a lex token representing a string.
If EOF is reached without finding a closing double quote, a :lex-error
token is returned."
  (let ((pos (point)))
    (right-char)
    (while (not (or (equal (char-after (point)) ?\") (parseclj-lex-at-eof?)))
      (if (equal (char-after (point)) ?\\)
          (right-char 2)
        (right-char)))
    (if (equal (char-after (point)) ?\")
        (progn
          (right-char)
          (parseclj-lex-token :string (buffer-substring-no-properties pos (point)) pos))
      (parseclj-lex-token :lex-error (buffer-substring-no-properties pos (point)) pos))))

(defun parseclj-lex-lookahead (n)
  "Return a lookahead string of N characters after point."
  (buffer-substring-no-properties (point) (min (+ (point) n) (point-max))))

(defun parseclj-lex-character ()
  "Return a lex token representing a character."
  (let ((pos (point)))
    (right-char)
    (cond
     ((equal (parseclj-lex-lookahead 3) "tab")
      (right-char 3)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (parseclj-lex-lookahead 5) "space")
      (right-char 5)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (parseclj-lex-lookahead 6) "return")
      (right-char 6)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (parseclj-lex-lookahead 7) "newline")
      (right-char 7)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (char-after (point)) ?u)
      (right-char 5)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (char-after (point)) ?o)
      (right-char 4)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     (t
      (right-char)
      (parseclj-lex-token :character (buffer-substring-no-properties pos (point)) pos)))))

(defun parseclj-lex-keyword ()
  "Return a lex token representing a keyword.
Keywords follow the same rules as symbols, except they might start with one
or two colon characters.

See `parseclj-lex-symbol', `parseclj-lex-symbol-start?'."
  (let ((pos (point)))
    (right-char)
    (when (equal (char-after (point)) ?:) ;; same-namespace keyword
      (right-char))
    (if (equal (char-after (point)) ?:) ;; three colons in a row => lex-error
        (progn
          (right-char)
          (parseclj-lex-token :lex-error (buffer-substring-no-properties pos (point)) pos :error-type :invalid-keyword))
      (progn
        (while (or (parseclj-lex-symbol-rest? (char-after (point)))
                   (equal (char-after (point)) ?#))
          (right-char))
        (parseclj-lex-token :keyword (buffer-substring-no-properties pos (point)) pos)))))

(defun parseclj-lex-comment ()
  "Return a lex token representing a comment."
  (let ((pos (point)))
    (goto-char (line-end-position))
    (when (equal (char-after (point)) ?\n)
      (right-char))
    (parseclj-lex-token :comment (buffer-substring-no-properties pos (point)) pos)))

(defun parseclj-lex-next ()
  "Consume characters at point and return the next lexical token.

See `parseclj-lex-token'."
  (if (parseclj-lex-at-eof?)
      (parseclj-lex-token :eof nil (point))
    (let ((char (char-after (point)))
          (pos  (point)))
      (cond
       ((parseclj-lex-at-whitespace?)
        (parseclj-lex-whitespace))

       ((equal char ?\()
        (right-char)
        (parseclj-lex-token :lparen "(" pos))

       ((equal char ?\))
        (right-char)
        (parseclj-lex-token :rparen ")" pos))

       ((equal char ?\[)
        (right-char)
        (parseclj-lex-token :lbracket "[" pos))

       ((equal char ?\])
        (right-char)
        (parseclj-lex-token :rbracket "]" pos))

       ((equal char ?{)
        (right-char)
        (parseclj-lex-token :lbrace "{" pos))

       ((equal char ?})
        (right-char)
        (parseclj-lex-token :rbrace "}" pos))

       ((parseclj-lex-at-number?)
        (parseclj-lex-number))

       ((parseclj-lex-symbol-start? char)
        (parseclj-lex-symbol))

       ((equal char ?\")
        (parseclj-lex-string))

       ((equal char ?\\)
        (parseclj-lex-character))

       ((equal char ?:)
        (parseclj-lex-keyword))

       ((equal char ?\;)
        (parseclj-lex-comment))

       ((equal char ?#)
        (right-char)
        (let ((char (char-after (point))))
          (cond
           ((equal char ?{)
            (right-char)
            (parseclj-lex-token :set "#{" pos))
           ((equal char ?_)
            (right-char)
            (parseclj-lex-token :discard "#_" pos))
           ((parseclj-lex-symbol-start? char t)
            (right-char)
            (parseclj-lex-token :tag (concat "#" (parseclj-lex-get-symbol-at-point (1+ pos))) pos))
           (t
            (while (not (or (parseclj-lex-at-whitespace?)
                            (parseclj-lex-at-eof?)))
              (right-char))
            (parseclj-lex-token :lex-error (buffer-substring-no-properties pos (point)) pos :error-type :invalid-hashtag-dispatcher)))))

       (t
        (concat ":(" (char-to-string char)))))))

(provide 'parseclj-lex)

;;; parseclj-lex.el ends here
