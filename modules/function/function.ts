import { DynamoDBDocumentClient, GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import type {
    Context,
    APIGatewayProxyEventV2,
    APIGatewayProxyResult,
} from "aws-lambda";

const ddbClient = new DynamoDBClient({ region: "ap-south-1" });
const ddbDocClient = DynamoDBDocumentClient.from(ddbClient);
const tableName = "visit-table"; // hash-key column name: pk

// lambda handler
export const handler = async (
    event: APIGatewayProxyEventV2,
    context: Context
): Promise<APIGatewayProxyResult> => {
    let body:any = {};
    let statusCode = 200;
    const headers = {
        "Content-Type": "application/json",
    };
    try {
        switch (event.routeKey) {
            case "GET /visits":
                body.visits = await getTotalVisitCount();
                break;
            case "POST /visits":
                if (!event.body) {
                    throw new Error("missing event body");
                }
                // expects a base64 encoded JSON string
                const { user_hash } = JSON.parse(atob(event.body));
                if (!user_hash) {
                    throw new Error("missing user_hash in event.body");
                }
                const exists = await checkDuplicateVisit(user_hash);
                if (exists) {
                    throw new Error("visitor already exists");
                }
                body.visits = await insertUserHash(user_hash);
                break;
            default:
                throw new Error(`Unsupported route: "${event.routeKey}"`);
        }
    } catch (err) {
        statusCode = 400;
        if (err instanceof Error) {
            body.error = err.message;
        } else {
            body.error = "An unknown error occurred";
        }
    } finally {
        body = JSON.stringify(body);
    }
    return {
        statusCode,
        body,
        headers,
    }
};

/**
 * Checks if a userhash exists
 * in the current month and year row.
 */
async function checkDuplicateVisit(
    user_hash: string
): Promise<boolean> {
    const res = await ddbDocClient.send(new GetCommand({
        TableName: tableName,
        Key: {
            pk: getCurrentMonthYearKey(),
        }
    }));
    if (!res.Item?.user_hashes) {
        return false;
    }
    return res.Item.user_hashes.includes(user_hash);
}

/**
 * - Returns updated visit count after inserting
 *
 * - Inserts `user_hash` for the current month
 * and year in `visit_month_year` pk row e.g. `visit_nov_2024`
 *
 * - **Also increases global visit count column by 1.**
 */
async function insertUserHash(
    userHash: string,
): Promise<number> {
    await ddbDocClient.send(new UpdateCommand({
        TableName: tableName,
        Key: {
            pk: getCurrentMonthYearKey(),
        },
        UpdateExpression: "SET user_hashes = list_append(if_not_exists(user_hashes, :empty), :user_hash)",
        ExpressionAttributeValues: {
            ":empty": [],
            ":user_hash": [userHash],
        }
    }))
    const updatedItem = await ddbDocClient.send(new UpdateCommand({
        TableName: tableName,
        Key: {
            pk: "total_visits",
        },
        UpdateExpression: "SET visits = if_not_exists(visits, :zero) + :incr",
        ExpressionAttributeValues: {
            ":zero": 0,
            ":incr": 1,
        },
        ReturnValues: "UPDATED_NEW",
    }));
    if (!updatedItem.Attributes?.visits) {
        throw new Error("total_visits row not updated");
    }
    return updatedItem.Attributes.visits;
}

/**
 * Returns total visit count till this date on the site
 */
async function getTotalVisitCount(): Promise<number> {
    const res = await ddbDocClient.send(new GetCommand({
        TableName: tableName,
        Key: {
            pk: "total_visits",
        }
    }));
    if (!res.Item?.visits) {
        console.warn("total_visits row not found");
        return 0;
    }
    return res.Item.visits;
}

function getCurrentMonthYearKey(): string {
    const date = new Date();
    const month = date.toLocaleString('default', { month: 'short' });
    const year = date.toLocaleString('default', { year: 'numeric' });
    return `visit#${month}#${year}`;
}
