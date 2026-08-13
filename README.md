# opensearch-ccs-issue-reproduction

You should be able to simply clone, and then run `./run-reproduction.sh`. Assuming you have docker installed.

In short:
- It spuns up three contains. 2 OpenSearch 2.19.6 and 1 OpenSearch 3.7.0 container
- Sets up security configuration on all three clusters that is exactly the same
- Runs a cross cluster query that shows:
    - OS2 -> OS2 works
    - OS3 -> OS2 does not work
- Creates the necessary change for OS3 -> OS2 to work
- Do another call showing that it works