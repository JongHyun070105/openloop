import unittest
from unittest.mock import Mock

from app.demo_analyzer import analyze_demo
from app.dynamo_repository import DynamoLoopRepository
from app.models import AnalyzeRequest, CreateLoopRequest
from app.repository import LoopRepository
from app.service import LoopService


class DynamoLoopRepositoryTests(unittest.TestCase):
    def _deadline_loop(self):  # type: ignore[no-untyped-def]
        analysis = analyze_demo(
            AnalyzeRequest(text="AI 공모전 접수 마감 8월 22일 23:59. 제출물: 작품 파일, 포트폴리오")
        )
        repository = LoopRepository(":memory:")
        try:
            return LoopService(repository).create(CreateLoopRequest(**analysis.model_dump()))
        finally:
            repository.close()

    def test_puts_metadata_and_dispatcher_compatible_checkpoint_items(self) -> None:
        client = Mock()
        repository = DynamoLoopRepository("openloop-test", client=client)
        loop = self._deadline_loop()

        repository.save(loop)

        calls = client.put_item.call_args_list
        self.assertEqual(len(calls), 1 + len(loop.checkpoints))
        metadata = calls[0].kwargs["Item"]
        self.assertEqual(metadata["PK"], {"S": f"LOOP#{loop.id}"})
        self.assertEqual(metadata["SK"], {"S": "METADATA"})
        self.assertEqual(metadata["GSI1PK"], {"S": "STATUS#OPEN"})
        checkpoint = calls[1].kwargs["Item"]
        self.assertEqual(checkpoint["GSI1PK"], {"S": "CHECKPOINT#OPEN"})
        self.assertTrue(checkpoint["GSI1SK"]["S"].endswith("Z"))
        self.assertEqual(checkpoint["userId"], {"S": loop.owner_id})

    def test_get_and_status_list_round_trip_documents(self) -> None:
        client = Mock()
        repository = DynamoLoopRepository("openloop-test", client=client)
        loop = self._deadline_loop()
        item = {"document": {"S": loop.model_dump_json()}}
        client.get_item.return_value = {"Item": item}
        client.query.return_value = {"Items": [item]}

        self.assertEqual(repository.get(loop.id), loop)
        listed = repository.list("open")
        self.assertEqual([candidate.id for candidate in listed], [loop.id])
        query = client.query.call_args.kwargs
        self.assertEqual(query["IndexName"], "GSI1")
        self.assertEqual(query["ExpressionAttributeValues"][":status"], {"S": "STATUS#OPEN"})

    def test_delete_removes_metadata_and_child_items(self) -> None:
        client = Mock()
        client.query.return_value = {
            "Items": [
                {"PK": {"S": "LOOP#1"}, "SK": {"S": "METADATA"}},
                {"PK": {"S": "LOOP#1"}, "SK": {"S": "CHECKPOINT#2"}},
            ]
        }
        repository = DynamoLoopRepository("openloop-test", client=client)

        self.assertTrue(repository.delete("1"))
        self.assertEqual(client.delete_item.call_count, 2)


if __name__ == "__main__":
    unittest.main()
