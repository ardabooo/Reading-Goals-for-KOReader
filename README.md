# reading goal plugin for koreader

a plugin that lets you set reading goals on your e-reader. works with percentage, page numbers, and stable page numbers. you can also set daily or weekly targets.

## how to install

1. download the `ReadingGoal.koplugin` folder
2. put it inside your koreader's `plugins/` directory
   - kobo: `.adds/koreader/plugins/`
   - kindle: `koreader/plugins/`
   - android: `koreader/plugins/`
3. restart koreader
4. open a book, go to tools menu, you'll see "reading goal" there

that's it. no other files need to be changed.

## what it does

### setting goals

you can set goals in two ways:

**go to a specific point:**
- set a percentage goal ("i want to reach 75%")
- set a page goal ("i want to reach page 200")
- set a stable page goal ("i want to reach stable page 150") - only works if you have stable page numbers enabled for the book

**read a certain amount from where you are now:**
- read x% more
- read x more pages
- read x more stable pages

### reminders

when you set a goal, there's a checkbox to enable progress reminders. if you turn it on, you can choose how often you want to be reminded. for example, setting it to 25% means you'll get notified at 25%, 50%, and 75% of your way through the goal.

the percentage is based on your goal progress, not the whole book. so if your goal is to read from page 100 to page 200, 50% reminder fires at page 150.

### daily and weekly goals

you can set page targets per day or per week:

- **this book only** - track how many pages you read in the current book each day/week
- **all books** - track total pages across every book you open

if you don't hit your daily target, the missed pages carry over to the next day. so if your goal is 30 pages/day and you only read 20, tomorrow you'll need to read 40.

you can check your progress anytime from the "view progress" option.

### status bar

the plugin can show your progress in the status bar and/or the alt status bar. toggle these from the checkboxes that appear when you set a goal.

- position goals show stuff like `⚑ 15% left` or `⚑ 42 pg left`
- daily/weekly goals show `⚑ 22/30 today` or `⚑ 150/210 wk`

## compatibility

- works on koreader v2025.10 and later
- works on all devices (kobo, kindle, android, pocketbook, etc.)
- stable page numbers require the feature to be enabled in koreader's settings for epub documents
- if you had an older version of this plugin, your existing goal data will carry over automatically

## license

agpl-3.0 (same as koreader)
