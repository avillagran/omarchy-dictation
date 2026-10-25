#!/usr/bin/env python3
import unittest
from report import words, prefix_distances
from prepare import Article

class Scoring(unittest.TestCase):

    def test_article_excludes_navigation_tables_and_citations(self):
        parser = Article()
        parser.feed('<div class="mw-parser-output"><table><tr><td>metadata</td></tr></table><p>One <sup class="reference">[1]</sup>two.</p><h2>Heading<span class="mw-editsection">edit</span></h2><div class="reflist"><ol><li>citation</li></ol></div><p>Three.</p></div>')
        self.assertEqual(' '.join(''.join(parser.out).split()), 'One two. Heading Three.')

    def test_unicode_and_punctuation(self):
        self.assertEqual(words('¡Árbol, ação! IT’S 1_2.'), ['árbol', 'ação', 'it', 's', '1', '2'])

    def test_edit_operations(self):
        self.assertEqual(prefix_distances(['a', 'b', 'c'], ['a', 'x', 'c', 'd'])[-1], 2)
        self.assertEqual(prefix_distances(['a', 'b', 'c'], [])[-1], 3)

    def test_shared_reference_penalizes_truncation(self):
        ref = words('one two three four five six')
        self.assertEqual(prefix_distances(ref, words('one two'))[-1], 4)
        costs = prefix_distances(ref, words('one two three four'))
        self.assertEqual(min(range(1, len(costs)), key=lambda n: costs[n]), 4)
if __name__ == '__main__':
    unittest.main()
