---
trigger: always_on
---

Do not create multiple SSH sessions to AWS. Either use the awscli or create a persistant SSH session and don't close it until you're done.

ssh -i ~/.ssh/p4td-key.pem ec2-user@46.137.83.83

Ensure you prioritise costs are kept to a minimum when making decisions about AWS infrastructure