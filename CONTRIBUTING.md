The development tracker for odbc_fdw is on GitHub:
http://github.com/devrimgunduz/odbc_fdw

---

1. [General](#general)
2. [Bugs](#bugs)
3. [Submitting contributions](#submitting-contributions)

---

# General

Every new feature (as well as bugfixes) should come through a [github pull requests](https://help.github.com/articles/using-pull-requests) and should have test cases for it.

Before you start working on a new bugfix or feature, we encourage you to first look up the open issues list to check there's no duplicate. 
If your issue is not described there, please create one explaining what you are going to do in order to help you and especially to avoid duplicate work.

There are several rules you should follow when a new pull request is created:

- Title has to be descriptive. If you are fixing a bug don't use just the ticket title or number.
- Explain what you have achieved in the description.
- If you've added a new datasource, please put it in the description in order to include and configure it in travis so the tests could pass.
- All tests [should pass](https://github.com/devrimgunduz/odbc_fdw/tree/master/test#how-to-execute-the-tests).

# Bugs

Here're some good tips to make a good bug report:

- First of all, check if the bug is already reported.
- If you've multiple issues, please file them in different reports.
- Once you decide to create a bug report, please use the template we provide, don't use one of your own.
- Make the title as descriptive as you can. Take into account that is the first information we receive.

# Submitting contributions

All contributions are welcome via [Github PR](https://github.com/devrimgunduz/odbc_fdw/pulls)
